import GarageLauncher

// `Garage.app/Contents/Helpers/garage.app/Contents/MacOS/garage`, reached through
// `Garage.app/Contents/MacOS/garage` (a link to the forwarder in Resources/launchers): the
// full CLI, in Rust and linked in. Starts the app (hidden) when a command needs its
// database and it is not running.
Launcher.run(.cli)
