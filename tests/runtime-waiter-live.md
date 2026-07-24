# Manual background-completion proof

This is a repeatable authenticated-runtime proof, not a CI claim. CI runs the
child script and validates its sentinel; only a live session can observe whether
a background child's completion actually wakes its parent.

1. From the dockmaster root, start `bash tests/runtime-waiter-child.sh 1` as
   background work (a background Bash command or a background Agent), and record
   the returned id.
2. Do not read a terminal session and do not poll a file. Wait for the runtime's
   own completion notification.
3. Pass only if the parent is woken by that completion and the child's stdout is
   exactly `WAITER_COMPLETION_OK`. Record runtime/version, the returned child id,
   and a UTC timestamp. Any timeout or manual terminal read is a failure.

This probes notification delivery only. The approval flow that depends on it is
`change-review` (`bin/dm-lavish.sh poll <id>` in the background); its ownership
and cleanup rules are asserted separately in the smoke suite.
