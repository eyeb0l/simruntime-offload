# Results: restart without the SSD, then reconnecting it (2026-11-10, session 8)

Restart test 2. Before the restart the SSD was released with `sro.sh eject`
(both runtimes detached with normal ejects, volume ejected, 12 s).

## Timeline (agent log and CoreSimulator.log)

| Time | Event |
|---|---|
| 19:21:14 | First agent run after login: both volumes absent, nothing to do. Two more no-op runs follow as other filesystems mount. |
| 19:21:45 | Xcode starts. |
| 19:21:49 | Xcode logs "Unable to discover any Simulator runtimes". Both devices unavailable; no error dialogs (observed by the project owner). |
| 19:22:12 | SSD plugged in; launchd starts the agent. |
| 19:22:13 | iOS 27.2 attached and linked (1 s). The service and Xcode register it in the same second. |
| 19:22:14 | iOS 27.0 attached and linked (1 s). |

## Outcomes

| Question | Result |
|---|---|
| With the SSD absent at login, does anything misbehave? | No. Simulators are unavailable, with no errors and no stale-link warnings. |
| Does a late-arriving SSD get picked up without polling? | Yes: both runtimes registered 2 s after the volume mounted. |
| Does Xcode's interface recover without a relaunch? | **Yes** (observed by the project owner): the simulators became available in the running Xcode. |
| Was a consent prompt needed? | No. |
| Internal runtime store | Still empty. |

## Notes

- Each attach took 1 s here, against 56 s for the first attach in the previous
  restart. The agent's priority was changed in between, but this attach also
  happened a minute after login rather than during it, so the improvement
  cannot be attributed to one cause. A further restart with the SSD connected
  would show whether the login-time delay is gone.
- launchd started the agent five times in this session; four were no-ops.
  `StartOnMount` fires for every filesystem, including the two images the
  agent itself attaches. Harmless, but a native tool should watch for its own
  volume through DiskArbitration instead.
