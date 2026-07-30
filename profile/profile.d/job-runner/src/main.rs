use std::ffi::{OsStr, OsString};
use std::io::{IsTerminal, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::System::Console::{
    CTRL_BREAK_EVENT, CTRL_C_EVENT, GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE,
    STD_OUTPUT_HANDLE, SetConsoleCtrlHandler,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JobObjectBasicAccountingInformation, JobObjectExtendedLimitInformation,
    QueryInformationJobObject, SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::Threading::{
    CREATE_SUSPENDED, CreateProcessW, GetExitCodeProcess, PROCESS_INFORMATION, ResumeThread,
    STARTF_USESTDHANDLES, STARTUPINFOW, TerminateProcess, WaitForSingleObject,
};

const INTERRUPT_GRACE: Duration = Duration::from_secs(3);
const WAIT_POLL_MS: u32 = 10;
static INTERRUPT_COUNT: AtomicU32 = AtomicU32::new(0);

unsafe extern "system" fn ctrl_handler(kind: u32) -> i32 {
    if kind == CTRL_C_EVENT || kind == CTRL_BREAK_EVENT {
        INTERRUPT_COUNT.fetch_add(1, Ordering::SeqCst);
        1
    } else {
        0
    }
}

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

fn append_windows_quoted(out: &mut Vec<u16>, arg: &OsStr) {
    let wide: Vec<u16> = arg.encode_wide().collect();
    let quote = wide.is_empty() || wide.iter().any(|c| [32u16, 9, 10, 11, 34].contains(c));
    if !quote {
        out.extend_from_slice(&wide);
        return;
    }

    out.push(b'"' as u16);
    let mut slashes = 0;
    for c in wide {
        if c == b'\\' as u16 {
            slashes += 1;
        } else if c == b'"' as u16 {
            out.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2 + 1));
            out.push(c);
            slashes = 0;
        } else {
            out.extend(std::iter::repeat_n(b'\\' as u16, slashes));
            slashes = 0;
            out.push(c);
        }
    }
    out.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2));
    out.push(b'"' as u16);
}

fn windows_command_line(args: &[OsString]) -> Vec<u16> {
    let mut result = Vec::new();
    for (index, arg) in args.iter().enumerate() {
        if index != 0 {
            result.push(b' ' as u16);
        }
        append_windows_quoted(&mut result, arg);
    }
    result.push(0);
    result
}

fn append_cmd_quoted(out: &mut Vec<u16>, arg: &OsStr) {
    out.push(b'"' as u16);
    for c in arg.encode_wide() {
        if c == b'"' as u16 {
            out.push(c);
        }
        out.push(c);
    }
    out.push(b'"' as u16);
}

fn batch_command_line(shell: &OsStr, args: &[OsString]) -> Vec<u16> {
    let mut result = Vec::new();
    append_windows_quoted(&mut result, shell);
    result.extend(" /d /s /v:off /c \"".encode_utf16());
    for (index, arg) in args.iter().enumerate() {
        if index != 0 {
            result.push(b' ' as u16);
        }
        append_cmd_quoted(&mut result, arg);
    }
    result.push(b'"' as u16);
    result.push(0);
    result
}

fn is_batch_file(path: &OsStr) -> bool {
    Path::new(path)
        .extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("cmd") || extension.eq_ignore_ascii_case("bat")
        })
}

fn wide_null(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain([0]).collect()
}

fn fail(operation: &str) -> i32 {
    fail_with_code(operation, unsafe { GetLastError() })
}

fn fail_with_code(operation: &str, code: u32) -> i32 {
    eprintln!(
        "jrun: {operation} failed: {}",
        std::io::Error::from_raw_os_error(code as i32)
    );
    125
}

fn job_is_empty(job: HANDLE) -> Result<bool, i32> {
    let mut accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
    if unsafe {
        QueryInformationJobObject(
            job,
            JobObjectBasicAccountingInformation,
            (&raw mut accounting).cast(),
            size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
            null_mut(),
        )
    } == 0
    {
        return Err(fail("QueryInformationJobObject"));
    }
    Ok(accounting.ActiveProcesses == 0)
}

fn should_force(interrupt_count: u32, elapsed: Duration) -> bool {
    interrupt_count >= 2 || (interrupt_count >= 1 && elapsed >= INTERRUPT_GRACE)
}

fn report_status(title: &str, detail: &str, color: u8) {
    let stderr = std::io::stderr();
    let is_terminal = stderr.is_terminal();
    let mut stderr = stderr.lock();
    if is_terminal {
        let _ = writeln!(stderr);
        let _ = writeln!(stderr, "\x1b[1;{color}m[jrun] {title}\x1b[0m");
        let _ = writeln!(stderr, "\x1b[{color}m       {detail}\x1b[0m");
    } else {
        let _ = writeln!(stderr, "jrun: {title}");
        let _ = writeln!(stderr, "jrun: {detail}");
    }
}

fn notice_interrupt(interrupt_started: &mut Option<Instant>) {
    if interrupt_started.is_none() {
        report_status(
            "Ctrl+C received",
            "Waiting up to 3 seconds for graceful shutdown. Press Ctrl+C again to force.",
            93,
        );
        *interrupt_started = Some(Instant::now());
    }
}

fn force_requested(interrupt_started: &mut Option<Instant>) -> bool {
    let interrupt_count = INTERRUPT_COUNT.load(Ordering::SeqCst);
    if interrupt_count == 0 {
        return false;
    }
    notice_interrupt(interrupt_started);
    let elapsed = interrupt_started
        .as_ref()
        .map_or(Duration::ZERO, Instant::elapsed);
    should_force(interrupt_count, elapsed)
}

fn terminate_job_and_wait(job: HANDLE) -> Result<(), i32> {
    if unsafe { TerminateJobObject(job, 130) } == 0 {
        return Err(fail("TerminateJobObject"));
    }
    while !job_is_empty(job)? {
        std::thread::sleep(Duration::from_millis(WAIT_POLL_MS.into()));
    }
    Ok(())
}

fn terminate_after_interrupt(job: HANDLE) -> Result<(), i32> {
    if INTERRUPT_COUNT.load(Ordering::SeqCst) >= 2 {
        report_status(
            "Second Ctrl+C received",
            "Terminating the process tree.",
            91,
        );
    } else {
        report_status(
            "Graceful shutdown timed out",
            "Terminating the process tree.",
            91,
        );
    }
    terminate_job_and_wait(job)
}

fn run() -> i32 {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: jrun <command> [arguments]");
        return 125;
    }

    let shell = is_batch_file(&args[0])
        .then(|| std::env::var_os("ComSpec").unwrap_or_else(|| OsString::from("cmd.exe")));

    if unsafe { SetConsoleCtrlHandler(Some(ctrl_handler), 1) } == 0 {
        return fail("SetConsoleCtrlHandler");
    }

    let job = Handle(unsafe { CreateJobObjectW(null(), null()) });
    if job.0.is_null() {
        return fail("CreateJobObjectW");
    }

    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if unsafe {
        SetInformationJobObject(
            job.0,
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    } == 0
    {
        return fail("SetInformationJobObject");
    }

    let application = shell.as_ref().map(|value| wide_null(value));
    let mut line = match shell.as_ref() {
        Some(value) => batch_command_line(value, &args),
        None => windows_command_line(&args),
    };
    let application_name = application.as_ref().map_or(null(), |value| value.as_ptr());

    let mut startup = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        dwFlags: STARTF_USESTDHANDLES,
        hStdInput: unsafe { GetStdHandle(STD_INPUT_HANDLE) },
        hStdOutput: unsafe { GetStdHandle(STD_OUTPUT_HANDLE) },
        hStdError: unsafe { GetStdHandle(STD_ERROR_HANDLE) },
        ..Default::default()
    };
    let mut process = PROCESS_INFORMATION::default();
    if unsafe {
        CreateProcessW(
            application_name,
            line.as_mut_ptr(),
            null(),
            null(),
            1,
            CREATE_SUSPENDED,
            null(),
            null(),
            &raw mut startup,
            &raw mut process,
        )
    } == 0
    {
        return fail("CreateProcessW");
    }
    let process_handle = Handle(process.hProcess);
    let _thread_handle = Handle(process.hThread);

    if unsafe { AssignProcessToJobObject(job.0, process_handle.0) } == 0 {
        let error = unsafe { GetLastError() };
        unsafe {
            TerminateProcess(process_handle.0, 125);
        }
        return fail_with_code("AssignProcessToJobObject", error);
    }

    if INTERRUPT_COUNT.load(Ordering::SeqCst) != 0 {
        report_status(
            "Ctrl+C received during startup",
            "Terminating the process tree.",
            91,
        );
        return 130;
    }
    if unsafe { ResumeThread(process.hThread) } == u32::MAX {
        let error = unsafe { GetLastError() };
        unsafe {
            TerminateProcess(process_handle.0, 125);
        }
        return fail_with_code("ResumeThread", error);
    }
    if INTERRUPT_COUNT.load(Ordering::SeqCst) != 0 {
        report_status(
            "Ctrl+C received during startup",
            "Terminating the process tree.",
            91,
        );
        return 130;
    }

    let mut interrupt_started = None;
    loop {
        match unsafe { WaitForSingleObject(process_handle.0, WAIT_POLL_MS) } {
            WAIT_OBJECT_0 => break,
            WAIT_TIMEOUT => {
                if force_requested(&mut interrupt_started) {
                    if let Err(code) = terminate_after_interrupt(job.0) {
                        return code;
                    }
                    return 130;
                }
            }
            _ => return fail("WaitForSingleObject"),
        }
    }

    let mut exit_code = 125;
    if unsafe { GetExitCodeProcess(process_handle.0, &raw mut exit_code) } == 0 {
        return fail("GetExitCodeProcess");
    }

    if INTERRUPT_COUNT.load(Ordering::SeqCst) != 0 || exit_code == 0xC000_013A {
        notice_interrupt(&mut interrupt_started);
        loop {
            match job_is_empty(job.0) {
                Ok(true) => return 130,
                Ok(false) => {}
                Err(code) => return code,
            }
            if force_requested(&mut interrupt_started) {
                if let Err(code) = terminate_after_interrupt(job.0) {
                    return code;
                }
                return 130;
            }
            std::thread::sleep(Duration::from_millis(WAIT_POLL_MS.into()));
        }
    }

    exit_code as i32
}

fn main() {
    std::process::exit(run());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display_command_line(line: Vec<u16>) -> String {
        String::from_utf16(&line[..line.len() - 1]).unwrap()
    }

    #[test]
    fn quotes_windows_arguments() {
        let args = [
            "tool.exe",
            "",
            "two words",
            "quote\"inside",
            "C:\\two words\\",
            "a\\\"b",
        ]
        .map(OsString::from);

        assert_eq!(
            display_command_line(windows_command_line(&args)),
            r#"tool.exe "" "two words" "quote\"inside" "C:\two words\\" "a\\\"b""#
        );
    }

    #[test]
    fn quotes_batch_arguments() {
        let args = ["script.cmd", "two words", "quote\"inside", "!PATH!"].map(OsString::from);

        assert_eq!(
            display_command_line(batch_command_line(OsStr::new("cmd.exe"), &args)),
            r#"cmd.exe /d /s /v:off /c ""script.cmd" "two words" "quote""inside" "!PATH!"""#
        );
    }

    #[test]
    fn recognizes_batch_extensions_case_insensitively() {
        assert!(is_batch_file(OsStr::new("script.cmd")));
        assert!(is_batch_file(OsStr::new("SCRIPT.BAT")));
        assert!(!is_batch_file(OsStr::new("script.ps1")));
        assert!(!is_batch_file(OsStr::new("program.exe")));
        assert!(!is_batch_file(OsStr::new("command")));
    }

    #[test]
    fn interrupt_escalation_policy() {
        assert!(!should_force(0, INTERRUPT_GRACE));
        assert!(!should_force(1, INTERRUPT_GRACE - Duration::from_millis(1)));
        assert!(should_force(1, INTERRUPT_GRACE));
        assert!(should_force(2, Duration::ZERO));
    }
}
