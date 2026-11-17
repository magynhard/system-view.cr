#!/usr/bin/env bash
# Sourced by AppRun. GTK/libadwaita choose the theme and display backend.
export GTK_DATA_PREFIX="$APPDIR/usr"
export GTK_EXE_PREFIX="$APPDIR/usr"
export GTK_PATH="$APPDIR/usr/lib/gtk-4.0"
export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
export GI_TYPELIB_PATH="$APPDIR/usr/lib/girepository-1.0"
export GDK_PIXBUF_MODULE_FILE="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
export GDK_PIXBUF_MODULEDIR="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
export GIO_MODULE_DIR="$APPDIR/usr/lib/gio/modules"
export XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
