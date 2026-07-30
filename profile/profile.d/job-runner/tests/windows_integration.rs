#![cfg(windows)]

use std::fs;
use std::io::Read;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, WAIT_TIMEOUT};
use windows_sys::Win32::System::Console::{
    AttachConsole, CTRL_C_EVENT, FreeConsole, GenerateConsoleCtrlEvent, SetConsoleCtrlHandler,
};
use windows_sys::Win32::System::Threading::{
    CREATE_NEW_CONSOLE, OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject,
};

const TEST_DIR: &str = "JRUN_TEST_DIR";
const TEST_FIXTURE: &str = "JRUN_TEST_FIXTURE";
const TEST_ROLE: &str = "JRUN_TEST_ROLE";
const ROOT_DELAY_MS: &str = "JRUN_TEST_ROOT_DELAY_MS";
const CHILD_DELAY_MS: &str = "JRUN_TEST_CHILD_DELAY_MS";
const SIGNAL_PID: &str = "JRUN_TEST_SIGNAL_PID";
const SECOND_SIGNAL_MS: &str = "JRUN_TEST_SECOND_SIGNAL_MS";
const NOTICE: &str = concat!(
    "jrun: Ctrl+C received\n",
    "jrun: Waiting up to 3 seconds for graceful shutdown. Press Ctrl+C again to force.\n"
);
const TIMEOUT_NOTICE: &str = concat!(
    "jrun: Graceful shutdown timed out\n",
    "jrun: Terminating the process tree.\n"
);
const SECOND_NOTICE: &str = concat!(
    "jrun: Second Ctrl+C received\n",
    "jrun: Terminating the process tree.\n"
);

static CTRL_RECEIVED: AtomicBool = AtomicBool::new(false);
static NEXT_TEST_DIR: AtomicU32 = AtomicU32::new(0);

unsafe extern "system" fn fixture_ctrl_handler(kind: u32) -> i32 {
    if kind == CTRL_C_EVENT {
        CTRL_RECEIVED.store(true, Ordering::SeqCst);
        1
    } else {
        0
    }
}

struct TestDir(PathBuf);

impl TestDir {
    fn new(name: &str) -> Self {
        let unique = NEXT_TEST_DIR.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "jrun-rust-test-{}-{unique}-{name}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn fixture_command(fixture: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--ignored", "--exact", "fixture_entry", "--nocapture"])
        .env(TEST_FIXTURE, fixture);
    command
}

fn spawn_jrun_fixture(fixture: &str, directory: &Path) -> Child {
    let mut command = Command::new(env!("CARGO_BIN_EXE_jrun"));
    command
        .arg(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "fixture_entry", "--nocapture"])
        .env(TEST_DIR, directory)
        .env(TEST_FIXTURE, fixture)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    command.spawn().unwrap()
}

fn wait_for_file(path: &Path, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while !path.exists() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn read_pid(path: &Path) -> u32 {
    fs::read_to_string(path).unwrap().trim().parse().unwrap()
}

fn process_is_alive(pid: u32) -> bool {
    let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
    if process.is_null() {
        return false;
    }
    let wait = unsafe { WaitForSingleObject(process, 0) };
    unsafe {
        CloseHandle(process);
    }
    wait == WAIT_TIMEOUT
}

fn wait_until_dead(pid: u32) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while process_is_alive(pid) {
        assert!(Instant::now() < deadline, "process {pid} remained alive");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn finish_child(mut child: Child, timeout: Duration) -> (ExitStatus, String) {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            let mut stderr = String::new();
            child
                .stderr
                .take()
                .unwrap()
                .read_to_string(&mut stderr)
                .unwrap();
            return (status, stderr);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("jrun did not exit within {timeout:?}");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn send_ctrl(pid: u32, second_after: Option<Duration>) {
    let mut command = fixture_command("signal");
    command
        .env(SIGNAL_PID, pid.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    if let Some(delay) = second_after {
        command.env(SECOND_SIGNAL_MS, delay.as_millis().to_string());
    }
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "signal helper failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn assert_elapsed(elapsed: Duration, minimum: Duration, maximum: Duration) {
    assert!(
        elapsed >= minimum && elapsed <= maximum,
        "elapsed {elapsed:?}, expected {minimum:?}..={maximum:?}"
    );
}

fn run_ctrl_scenario(
    name: &str,
    root_delay: Duration,
    child_delay: Duration,
    second_after: Option<Duration>,
) -> (Duration, String, TestDir) {
    let directory = TestDir::new(name);
    let root_ready = directory.0.join("root.ready");
    let child_ready = directory.0.join("child.ready");
    let root_delay_ms = root_delay.as_millis().to_string();
    let child_delay_ms = child_delay.as_millis().to_string();

    let mut command = Command::new(env!("CARGO_BIN_EXE_jrun"));
    command
        .arg(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "fixture_entry", "--nocapture"])
        .env(TEST_DIR, &directory.0)
        .env(TEST_FIXTURE, "ctrl")
        .env(ROOT_DELAY_MS, root_delay_ms)
        .env(CHILD_DELAY_MS, child_delay_ms)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NEW_CONSOLE);
    let child = command.spawn().unwrap();

    wait_for_file(&root_ready, Duration::from_secs(10));
    wait_for_file(&child_ready, Duration::from_secs(10));
    let started = Instant::now();
    send_ctrl(child.id(), second_after);
    let (status, stderr) = finish_child(child, Duration::from_secs(6));
    let elapsed = started.elapsed();

    assert_eq!(status.code(), Some(130));
    wait_until_dead(read_pid(&root_ready));
    wait_until_dead(read_pid(&child_ready));
    (elapsed, stderr, directory)
}

fn exit_fixture() {
    std::process::exit(37);
}

#[allow(clippy::zombie_processes)] // The test requires the child to outlive its root.
fn orphan_fixture() {
    let directory = PathBuf::from(std::env::var_os(TEST_DIR).unwrap());
    if std::env::var(TEST_ROLE).as_deref() == Ok("child") {
        fs::write(directory.join("child.pid"), std::process::id().to_string()).unwrap();
        std::thread::sleep(Duration::from_secs(30));
        return;
    }

    fixture_command("orphan")
        .env(TEST_ROLE, "child")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    wait_for_file(&directory.join("child.pid"), Duration::from_secs(5));
}

fn ctrl_fixture() {
    CTRL_RECEIVED.store(false, Ordering::SeqCst);
    assert_ne!(
        unsafe { SetConsoleCtrlHandler(Some(fixture_ctrl_handler), 1) },
        0
    );

    let directory = PathBuf::from(std::env::var_os(TEST_DIR).unwrap());
    let role = std::env::var(TEST_ROLE).unwrap_or_else(|_| "root".to_owned());
    let mut child = if role == "root" {
        Some(
            fixture_command("ctrl")
                .env(TEST_ROLE, "child")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        )
    } else {
        None
    };

    fs::write(
        directory.join(format!("{role}.ready")),
        std::process::id().to_string(),
    )
    .unwrap();
    while !CTRL_RECEIVED.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(10));
    }

    let delay_name = if role == "root" {
        ROOT_DELAY_MS
    } else {
        CHILD_DELAY_MS
    };
    let delay = std::env::var(delay_name).unwrap().parse::<u64>().unwrap();
    std::thread::sleep(Duration::from_millis(delay));
    fs::write(directory.join(format!("{role}.graceful")), "graceful\n").unwrap();
    if let Some(child) = child.as_mut() {
        child.wait().unwrap();
    }
}

fn signal_console_fixture() {
    let pid = std::env::var(SIGNAL_PID).unwrap().parse().unwrap();
    let second_after = std::env::var(SECOND_SIGNAL_MS)
        .ok()
        .map(|value| Duration::from_millis(value.parse().unwrap()));

    unsafe {
        if FreeConsole() == 0 {
            assert_eq!(GetLastError(), 6);
        }
        assert_ne!(AttachConsole(pid), 0);
        assert_ne!(SetConsoleCtrlHandler(None, 1), 0);
        assert_ne!(GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0), 0);
        if let Some(delay) = second_after {
            std::thread::sleep(delay);
            assert_ne!(GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0), 0);
        }
        std::thread::sleep(Duration::from_millis(50));
        assert_ne!(SetConsoleCtrlHandler(None, 0), 0);
        assert_ne!(FreeConsole(), 0);
    }
}

#[test]
#[ignore]
fn fixture_entry() {
    match std::env::var(TEST_FIXTURE).as_deref() {
        Ok("exit") => exit_fixture(),
        Ok("orphan") => orphan_fixture(),
        Ok("ctrl") => ctrl_fixture(),
        Ok("signal") => signal_console_fixture(),
        _ => {}
    }
}

#[test]
fn preserves_root_exit_code() {
    let directory = TestDir::new("exit");
    let child = spawn_jrun_fixture("exit", &directory.0);
    let (status, stderr) = finish_child(child, Duration::from_secs(5));

    assert_eq!(status.code(), Some(37));
    assert!(stderr.is_empty());
}

#[test]
fn kills_leftover_descendants_after_normal_root_exit() {
    let directory = TestDir::new("orphan");
    let child_pid_path = directory.0.join("child.pid");
    let child = spawn_jrun_fixture("orphan", &directory.0);
    wait_for_file(&child_pid_path, Duration::from_secs(5));
    let (status, stderr) = finish_child(child, Duration::from_secs(5));

    assert_eq!(status.code(), Some(0));
    assert!(stderr.is_empty());
    wait_until_dead(read_pid(&child_pid_path));
}

#[test]
fn ctrl_c_allows_graceful_tree_shutdown() {
    let (elapsed, stderr, directory) = run_ctrl_scenario(
        "graceful",
        Duration::from_secs(1),
        Duration::from_millis(500),
        None,
    );

    assert_elapsed(
        elapsed,
        Duration::from_millis(800),
        Duration::from_millis(2500),
    );
    assert_eq!(stderr, NOTICE);
    assert_eq!(
        fs::read_to_string(directory.0.join("root.graceful")).unwrap(),
        "graceful\n"
    );
    assert_eq!(
        fs::read_to_string(directory.0.join("child.graceful")).unwrap(),
        "graceful\n"
    );
}

#[test]
fn ctrl_c_force_kills_tree_after_three_seconds() {
    let (elapsed, stderr, directory) = run_ctrl_scenario(
        "timeout",
        Duration::from_secs(10),
        Duration::from_secs(10),
        None,
    );

    assert_elapsed(
        elapsed,
        Duration::from_millis(2800),
        Duration::from_millis(4500),
    );
    assert_eq!(stderr, format!("{NOTICE}{TIMEOUT_NOTICE}"));
    assert!(!directory.0.join("root.graceful").exists());
    assert!(!directory.0.join("child.graceful").exists());
}

#[test]
fn second_ctrl_c_force_kills_tree_immediately() {
    let (elapsed, stderr, directory) = run_ctrl_scenario(
        "second",
        Duration::from_secs(10),
        Duration::from_secs(10),
        Some(Duration::from_millis(500)),
    );

    assert_elapsed(
        elapsed,
        Duration::from_millis(350),
        Duration::from_millis(2000),
    );
    assert_eq!(stderr, format!("{NOTICE}{SECOND_NOTICE}"));
    assert!(!directory.0.join("root.graceful").exists());
    assert!(!directory.0.join("child.graceful").exists());
}
