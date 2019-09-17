# gateofstorms_metaserver
This reposity houses the source code for the Gate of Storms unofficial metaserver for Myth 2.

A live version of the metaserver can be found at http://www.gateofstorms.net/.

Development
-----------
xwing_math is written in the [D Programming Language](https://dlang.org/) and uses the [vibe.d](http://vibed.org/)
library to host the web interface. It currently supports Windows and Linux (Ubuntu and likely others).

Install the [D compiler](https://dlang.org/download.html) and [DUB](http://code.dlang.org/download) on your platform
of choice and build/run the application by invoking `dub` from the command line in the root directory.

NOTE: The metaserver uses the mysql-lited library for database access which currently seems to require 64-bit
compilation. Additionally there are various D-related linking issues that crop up from time to time on Windows 32-bit
builds, so I highly recommend building 64-bit binaries. On Windows this can be accomplished via "dub --arch=x86_64",
while on most modern Linux distributions it is generally the default already.

Execution
---------
By default the metaserver will run in a "test mode" with no database access and no web server. See metaserver_config.d
and main.d for more information on creating a config file and setting command line flags.

Additional Setup on Linux
-------------------------
On Linux you may also need to install the dependencies for vibe.d. See the Linux section on
[this page](https://github.com/vibe-d/vibe.d) for more information.

In the default config, the application will attempt to listen on port 80 (HTTP) which several Linux
distributions do not allow for non-priviledged accounts. Other than running with an elevated account or
changing the default port, on recent versions of Linux it is possible to allow an executable to bind to
these priviledged ports via the following command (after building):
```
sudo setcap 'cap_net_bind_service=+ep' /[path]/xwing_math
```
