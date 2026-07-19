# Manual native waiter proof

This is a repeatable authenticated-runtime proof, not a CI claim. CI runs the
child script and validates its sentinel; only a live collaboration parent can
observe whether completion wakes its mailbox.

1. From the dockmaster root, derive
   `bin/dm-thread-name.sh runtime-waiter-probe review_waiter`.
2. Spawn exactly one no-fork child with that name. Its entire job is to run
   `bash tests/runtime-waiter-child.sh 1` synchronously and return only stdout.
3. The parent calls the native mailbox wait once. Do not read a terminal session
   or poll a file.
4. Pass only if the parent receives the child completion and exact
   `WAITER_COMPLETION_OK`. Record runtime/version, returned child id, exact thread
   name, and UTC timestamp. Any timeout, duplicate name, or manual terminal read
   is a failure.

This probes notification delivery only. Durable waiter ownership and terminal
clearing are asserted separately in the parity and smoke suites.
