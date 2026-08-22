# ---- Node toolchain (mise shims on PATH; `npm run` routed through the job runner) ----
function npm {
    $__target = Resolve-PwshNativeCommand -Name 'npm'
    if ($args.Count -gt 0 -and $args[0] -in 'run', 'run-script') {
        Invoke-JobProcess -FilePath $__target.Source -ArgumentList ([string[]]$args)
    }
    else { & $__target.Source @args }
}
