<!-- -*- coding: utf-8; indent-tabs-mode:nil;  -*- -->

gaplay.el
==========

  gaplay.el is a GStreamer based audio player for GNU Emacs.

## Features:

  * Play any format supported by GStreamer (including ogg, mp3, aac and others).
  * Can play both local and remote playlist (.m3u and .pls only).

## Platforms:
  * Linux and OS-X

## Requirements:

  gaplay.el requires the following softwares to be installed.

  * GNU Emacs 22.1 or newer (23.x recommended)
  * [GStreamer 0.10](http://gstreamer.freedesktop.org/)
  * python2.5 or newer - not including python3
  * [gst-python](http://gstreamer.freedesktop.org/modules/gst-python.html)

## Installation:

1. Install GStreamer and gstreamer-plugins packages (if you haven't already).

    For example on my Linux box (Lubuntu 12.10):

        $ sudo apt-get install libgstreamer0.10
        $ sudo apt-get install gstreamer0.10-plugins-base
        $ sudo apt-get install gstreamer0.10-plugins-good
        $ sudo apt-get install gstreamer0.10-plugins-bad
        $ sudo apt-get install gstreamer0.10-plugins-ugly
        $ sudo apt-get install python-gst0.10
        $ sudo apt-get install gstreamer0.10-alsa 

2. Getting the source files (`gaplay.el` and `gaplay.py`)

    If you have installed git:

            $ git clone git://github.com/te223/gaplay-el.git

    else:
    * go to <https://github.com/te223/gaplay-el>.
    * click `ZIP` icon to download source code as zip archive.
    * unpack it.

3. Copy `gaplay.el` and `gaplay.py` to somewhere in your emacs `load-path`.  
   (e.g /usr/local/share/emacs/site-lisp, ~/elisp )

        for example:
        $ sudo cp gaplay.el /usr/local/share/emacs/site-lisp/
        $ sudo cp gaplay.py /usr/local/share/emacs/site-lisp/

4. Add this into your .emacs file (or ~/.emacs.d/init.el)

        (autoload 'gaplay "gaplay" "A GStreamer based audio player" t)
        (autoload 'gaplay-load "gaplay" nil t)
        ;;
        ;;; Specify which python executable, if necessary.
        ;;; -- default is "python" 
        ;; (setq gaplay-python-command "/opt/local/bin/python2.7") 

5. Restart Emacs, and type `M-x gaplay` or `M-x gaplay-load`.


----------------------------------------------------------------

**For more information**, installation, customization, etc.,
please refer to the header comments of `gaplay.el` source file. 


