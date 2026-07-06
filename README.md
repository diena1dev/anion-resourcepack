it's best to symlink the resource pack in a development environment.

create a file named `allowed_symlinks.txt` in your `.minecraft` root directory

add the line `[regex].*` to it, then save.

create a symlink to the resource pack's location, then restart your machine (symlinks are weird and sometimes require a restart to work properly).
