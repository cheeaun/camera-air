# RTK - Rust Token Killer (Codex CLI)

**Usage**: Token-optimized CLI proxy for shell commands.

## Rule

Always prefix shell commands with `rtk`, except `xcodebuild`.

Examples:

```bash
rtk git status
rtk cargo test
rtk npm run build
rtk pytest -q
xcodebuild -scheme CameraAir -destination 'platform=iOS Simulator,name=iPhone 13 mini' build
```

## Meta Commands

```bash
rtk gain            # Token savings analytics
rtk gain --history  # Recent command savings history
rtk proxy <cmd>     # Run raw command without filtering
```

## Verification

```bash
rtk --version
rtk gain
which rtk
```
