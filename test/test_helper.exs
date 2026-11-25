# The tests wait for events, which come as soon as they happen: the timeout
# is only how long a failing one takes, generous for a loaded machine.
ExUnit.start(assert_receive_timeout: 5_000)
