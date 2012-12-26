;;; gaplay.el --- an audio player for GNU Emacs. -*- coding: utf-8 -*-

;; Copyright (C) 2012 Tetsu Takaishi

;; Author: Tetsu Takaishi <tetsuhumi@aa.bb-east.ne.jp>
;; Created: Mon Nov 19 2012
;; Version: 0.8.1
;; Keywords: multimedia

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.


;;; Commentary:

;;  gaplay.el is a GStreamer based audio player for GNU Emacs.

;; Features:
;; ==========
;;  *Play any formats supported by GStreamer (including ogg,mp3,aac and others).
;;  *Can play both local and remote playlist (.m3u and .pls only).

;; Requirements:
;; =============
;; gaplay.el requires the following softwares to be installed
;;   * GNU Emacs 22.1 or newer (23.x recommended)
;;   * GStreamer 0.10 (http://gstreamer.freedesktop.org/)
;;   * python2.5 or newer - not including python3
;;   * gst-python (http://gstreamer.freedesktop.org/modules/gst-python.html)

;; Installation:
;; =============
;;   1. Install GStreamer and gstreamer-plugins packages (if you haven't already).
;;     For example on my Linux box (Lubuntu 12.10):
;;       $ sudo apt-get install libgstreamer0.10
;;       $ sudo apt-get install gstreamer0.10-plugins-base
;;       $ sudo apt-get install gstreamer0.10-plugins-good
;;       $ sudo apt-get install gstreamer0.10-plugins-bad
;;       $ sudo apt-get install gstreamer0.10-plugins-ugly
;;       $ sudo apt-get install python-gst0.10
;;       $ sudo apt-get install gstreamer0.10-alsa 
;;
;;     For example on my macbook (OSX10.6 + MacPorts)
;;       $ sudo port install gstreamer
;;       $ sudo port install gst-plugins-base
;;       $ sudo port install gst-plugins-good
;;       $ sudo port install gst-plugins-bad
;;       $ sudo port install gst-plugins-ugly
;;       $ sudo port install py27-gst-python
;; 
;;   2. Getting the source files (`gaplay.el` and `gaplay.py`)
;;     If you have installed git:
;;	 $ git clone git://github.com/te223/gaplay-el.git
;;     else:
;;       * go to <https://github.com/te223/gaplay-el>.
;;       * click `ZIP` icon to download source code as zip archive.
;;       * unpack it.
;; 
;;   3. Copy `gaplay.el` and `gaplay.py` to somewhere in your emacs `load-path`.  
;;      (e.g /usr/local/share/emacs/site-lisp, ~/elisp )
;;      for example:
;;       $ sudo cp -p gaplay.el gaplay.py /usr/local/share/emacs/site-lisp/
;;
;;   4. Add this into your .emacs file (or ~/.emacs.d/init.el)
;;       ;;
;;       (autoload 'gaplay "gaplay" "A GStreamer based audio player" t)
;;       (autoload 'gaplay-load "gaplay" nil t)
;;       ;;
;;       ;;; Specify which python executable, if necessary.
;;       ;;;   -- default is "python".
;;       ;; (setq gaplay-python-command "/opt/local/bin/python2.7") 
;;
;;   5. Restart Emacs, and type `M-x gaplay' or `M-x gaplay-load'.

;; Customization:
;; ==============
;; If necessary, you can set gaplay-mode-hook in your .emacs as follows.
;;   (add-hook 'gaplay-mode-hook
;;     '(lambda ()
;;        ;; (setq gaplay-loop-mode t) ;; set play mode to `repeat`
;;        ;; (setq gaplay-shuffle-mode t) ;; set play mode to `shuffle`
;;   
;;        ;; (setq gaplay-keybindings-visible nil) ;; hide keybindings help
;;   
;;        ;; (setq gaplay-player-gain 1.0) ;;set volume to 100% (default is 0.8)
;;   
;;        ;;; examples of changing the key bindings
;;        ;; (local-set-key "u" 'gaplay-load-url) ;; shortcut to \C-u o 
;;        ;; (local-set-key [(down)] 'gaplay-play-next) ;;bind downarrow to play next
;;        ;; (local-set-key [(up)] 'gaplay-play-previous)
;;        ))

;; Known bugs:
;; ===========
;; on osx:
;;   *strange behavior when sleep-mode
;;   *headphone-jack sense doesn't work while playing

;; Note:
;; =====
;; How to listen to Shoutcast Stream with emacs-w3m and gaplay.el:
;;  (add-hook 'w3m-mode-hook
;;    '(lambda ()
;;       (add-to-list
;;        'w3m-content-type-alist
;;        (list "audio/x-scpls" "\\.pls\\'" 'gaplay-load nil) t)
;;       (add-to-list
;;        'w3m-content-type-alist
;;        (list "audio/x-mpegurl" "\\.m3u\\'" 'gaplay-load nil) t)
;;       ))  

;;; Code:

(require 'cl)
(require 'url-parse)
(require 'url-util)

(setq gaplay-debug-mode nil)
;; (setq gaplay-debug-mode t)

;; **************** Macro define *********************************
(defmacro gaplay-defvar (sym value &optional docstr)
  (if gaplay-debug-mode
      `(setq ,sym ,value) 
    `(defvar ,sym ,value ,@(and docstr (list docstr)))))

;; Show current buffer point to window if buffer has window
(defun gaplay-show-point (&optional pnt)
  (let ((win (get-buffer-window (current-buffer))))
    (if win (set-window-point win (or pnt (point))))))

(defun gaplay-log-message (buffer fmt &rest args)
  "Debug function for display message to buffer\n
FMT and ARGS are same as `(message FMT ARG ...)'"
  (with-current-buffer (get-buffer-create buffer)
    (let* ((save-point (point)) (last-p (eq save-point (point-max))))
      (goto-char (point-max))
      (insert (if args (apply #'format `(,fmt ,@args)) fmt))
      (insert "\n")
      (if last-p (gaplay-show-point) (goto-char save-point))
      nil
      )))

(defmacro gaplay-log (fmt &rest args)
  (if gaplay-debug-mode `(gaplay-log-message "*gaplay-log*" ,fmt ,@args) nil))

;; *********** Define Variable *****************************************
(defconst gaplay-version "0.8.0p1")
(gaplay-defvar gaplay-python-command
	       ;; "/opt/local/bin/python" ;; when installed by MacPorts
	       ;; "/usr/local/bin/python" ;; 
	       ;; "/usr/bin/python"
	       "python"
	       "*Your python2.XX command path"
	       )
;; (gaplay-defvar gaplay-player-script "/usr/local/bin/gaplay.py")
(gaplay-defvar
 gaplay-player-script
 (expand-file-name "gaplay.py" (file-name-directory load-file-name))
 "*gst player program path")

(gaplay-defvar gaplay-player-script-options '())

(gaplay-defvar gaplay-buffer-name "*gaplay*")
;; timeline
(gaplay-defvar gaplay-timeline-length 50 "*Timeline length")
(gaplay-defvar gaplay-timeline-left ?. "*left side character of timeline")
(gaplay-defvar gaplay-timeline-right ?\  "*right side character of timeline")
(gaplay-defvar gaplay-timeline-bar 
	       #("<=>" 0 3 (face secondary-selection))
	       "*String of timeline-bar")

(gaplay-defvar gaplay-seeking-seconds 5)

(gaplay-defvar gaplay-shrink-window-height 4)

(gaplay-defvar gaplay-read-url-history nil)

(gaplay-defvar gaplay-avfile-extensions
	       '("mp3" "mp4" "m4a" "aac" "ogg" "oga" "wav"
		 "flv" "avi" "webm" "mov" "wmv" "rm" "wmx" "mpg" "mpeg"
		 )
	       "*Extentions of all Gstreamer supported audio formats.
Fix-me, there are many formats other than these, but I don't know.")

(gaplay-defvar gaplay-playlist-extensions '("m3u" "pls"))

(gaplay-defvar gaplay-mode-hook nil "*Hook called in gaplay-mode")

(gaplay-defvar gaplay-mode-map nil)
(unless gaplay-mode-map
  (let ((kmap (make-sparse-keymap)))
    (define-key kmap "o" 'gaplay-load) ;; play music file 
    (define-key kmap "\C-co" 'gaplay-load-m3u) ;; load m3u playlist
    (define-key kmap "a" 'gaplay-add) ;; add music file and play
    (define-key kmap "\C-ca" 'gaplay-add-m3u) ;; add m3u playlist and play
    (define-key kmap "c" 'gaplay-shoutcast) ;; load music file 
    (define-key kmap "s" 'gaplay-stop) ;; stop playing
    (define-key kmap "q" 'gaplay-quit) ;; quit
    (define-key kmap "r" 'gaplay-replay) ;; rewind and play
    (define-key kmap " " 'gaplay-toggle-pause) ;; pause/continue
    (define-key kmap "+" 'gaplay-up-gain) ;; up volume
    (define-key kmap ";" 'gaplay-up-gain) ;; up volume
    (define-key kmap "-" 'gaplay-down-gain) ;; down volume
    (define-key kmap "=" 'gaplay-down-gain) ;; down volume
    (define-key kmap "M" 'gaplay-mute) ;; mute on/off
    (define-key kmap "L" 'gaplay-toggle-loop) ;; loop on/off
    (define-key kmap "S" 'gaplay-toggle-shuffle) ;; shuffle on/off

    (define-key kmap [(left)] 'gaplay-seek-backward) ;; step backward
    (define-key kmap "[" 'gaplay-seek-backward) ;; step backward
    (define-key kmap "b" 'gaplay-seek-backward) ;; step backward

    (define-key kmap [(right)] 'gaplay-seek-forward) ;; step forward
    (define-key kmap "]" 'gaplay-seek-forward) ;; step forward
    (define-key kmap "f" 'gaplay-seek-forward) ;; step forward

    (define-key kmap [(meta left)] 'gaplay-seek-bbackward) ;; step backward
    (define-key kmap "\M-[" 'gaplay-seek-bbackward) ;; step backward
    (define-key kmap [(meta right)] 'gaplay-seek-fforward) ;; step forward
    (define-key kmap "\M-]" 'gaplay-seek-fforward) ;; step forward

    (define-key kmap "j" 'gaplay-jump) ;; jump to 

    (define-key kmap "\C-ck" 'gaplay-stop/interrupt) 
    ;; (define-key kmap [(up)] 'gaplay-play-previous)
    (define-key kmap "p" 'gaplay-play-previous)
    ;; (define-key kmap [(down)] 'gaplay-play-next)
    (define-key kmap "n" 'gaplay-play-next)
    (define-key kmap "l" 'gaplay-show-plylst)
    (define-key kmap "^" 'gaplay-shrink-player)
    (define-key kmap "?" 'gaplay-show-keybind)
    (when gaplay-debug-mode ;; for debug
      (define-key kmap "\C-cd" 'gaplay-send-rawcommand)
      (define-key kmap "\C-cs" 'gaplay-raw-stop)
      )
    
    (setq gaplay-mode-map kmap)))

(defun gaplay-trim (str)
  (replace-regexp-in-string
   "^[ \\\t\\\r\\\n]+" ""
   (replace-regexp-in-string "[ \\\t\\\r\\\n]+$" "" str)))

(defun gaplay-chop (str) (replace-regexp-in-string "[\n\r]+$" "" str))

;; Convert STR as a decimal number.
;; If cannot interpret as a number, return nil
(defun gaplay-string-to-number (str)
  (let ((str (gaplay-trim str)))
    (let ((num (string-to-number str)))
      (if (zerop num) 
	  (and (not (string= str ""))
	       (string-match "^[-+]?[0-9]*\\.?[0-9]*e?[-+]?[0-9]*$" str)
	       num) num))))

(defun gaplay-string-join (strlst term)
  (mapconcat '(lambda (x) x) strlst term))

(defun gaplay-url-p (str) (string-match "^[A-Za-z0-9_-]+://.+" str))
(defun gaplay-url-file-p (str)
  (let ((proto (url-type (url-generic-parse-url str))))
    (or (null proto) (string= proto "file"))))
(defun gaplay-url-http-p (str)
  (let ((proto (url-type (url-generic-parse-url str))))
    (or (string= proto "http") (string= proto "https"))))

(defun gaplay-truncate (str width &optional tail)
  "Truncate string STR"
  (let ((ret (truncate-string-to-width str width)))
    (if (and tail (not (string= ret str))) (concat ret tail) ret)))

(defun gaplay-ask-yesno (prompt &optional default)
  (let ((ans (downcase
	      (gaplay-trim (read-string prompt nil nil (or default "no"))))))
    (if (string-match "^\\(y\\|ok\\)" ans) t nil)))

(defun gaplay-flatten (lst)
  "Flatten LST, LST must be pure-list
e.g.
  (gaplay-flatten '(1 (2 (3 4) 5) 6)) ;-> (1 2 3 4 5 6)
  But, (gaplay-flatten '(1 (2 (3 . 4) 5) 6)) ;-> ERROR"
  (mapcan
   #'(lambda (e)
       (if (consp e) (gaplay-flatten e)  (list e))) lst))

(defun gaplay-get-alist (key alist &optional fallback)
  (let ((find (assq key alist)))
    (if find (cdr find) fallback)))
(defun gaplay-add-alist (key val alist)
  (let ((find (assq key alist)))
    (if find (progn (rplacd find val) alist)
      (cons (cons key val) alist))))
(defun gaplay-delete-alist (key alist)
  (let* ((alist (cons nil alist))
	 (ret alist))
    (catch 'break
      (while (cdr alist)
	(if (eq (car (cadr alist)) key)
	    (progn (rplacd alist (cddr alist))
		   (throw 'break nil)))
	(setq alist (cdr alist))))
    (cdr ret)))

;; (gaplay-map-alist 'list '((:a . "a") (:b . "d") (:c . "c")))
;; -> ((:a "a") (:b "d") (:c "c"))
(defun gaplay-map-alist (_foo_ _alist_)
  (mapcar #'(lambda (_x_) (funcall _foo_ (car _x_) (cdr _x_))) _alist_))

(defun gaplay-each-alist (_foo_ _alist_)
  (mapc #'(lambda (_x_) (funcall _foo_ (car _x_) (cdr _x_))) _alist_))

;; (gaplay-str2sec "12:23") ;-> 743 (gaplay-str2sec "1:12:23") ;-> 4343
;; (gaplay-str2sec "") ;-> 0  (gaplay-str2sec "-1") ;-> -1
;; (gaplay-str2sec "#:32:") ;-> nil (gaplay-str2sec "aa") ;-> nil
(defun gaplay-str2sec (str)
  (let ((slist (nreverse (split-string str ":"))))
    (if (and (<= (length slist) 3) (< 0 (length slist))
	     (not (find-if #'(lambda (s) (string-match "[^-+0-9 ]+" s)) slist)))
	(let ((seconds 0) (m 1))
	  (mapc #'(lambda (s)
		    (setq seconds
			  (+ seconds (* m (string-to-number s))))
		    (setq m (* m 60))) slist)
	  (round seconds))
      nil)))

;; (gaplay-sec2str 743) ;-> "12:23"  (gaplay-sec2str 4343) ;-> "01:12:23"
;; (gaplay-sec2str 0) ;-> "00:00"
;; seconds must be >= 0
(defun gaplay-sec2str (seconds)
  (let ((h (/ seconds 3600)) (m (% seconds 3600)))
    (let ((m (/ m 60)) (s (% m 60)))
      (if (<= h 0) (format "%02d:%02d" m s)
	(format "%02d:%02d:%02d" h m s)))))

(defun gaplay-collect (_foo_ _seq_)
  "e.g. (gaplay-collect 'evenp '(1 2 3 4 5 6)) -> (2 4 6)"
  (mapcan '(lambda (_x_) (if (funcall _foo_ _x_) (list _x_) nil)) _seq_))

(defun gaplay-collect* (_foo_ &rest _seqlist_)
  "e.g.
    (gaplay-collect* 'cdr '((a b c) (a) (d e f g) nil (x y))) 
    => ((b c) (e f g) (y))
    (gaplay-collect*
       '(lambda (x y) (if (zerop y) nil (/ x y)))
          '(10 20 30) '(2 0 10))
    => (5 4)"
  (apply 'mapcan
	 (cons 
	  '(lambda (&rest _args_)
	     (let ((_result_ (apply _foo_ _args_)))
	       (if _result_ (list _result_) nil))) _seqlist_)))

;; local kill-buffer-hook handler
(defun gaplay-kill-buffer-handler ()
  ;; kill process
  (gaplay-disconnect)
  ;;  mada
  ;; kill timer
  (when (timerp gaplay-message-timer)
    (cancel-timer gaplay-message-timer)
    (gaplay-log "cancel message-timer"))
  ;; delete anchor
  (mapc #'(lambda (anchor)
	    (gaplay-anchor:clear anchor)) gaplay-anchor-list)
  ;; kill plylst-buffer
  (if (bufferp gaplay-plylst-buffer)
      (progn
	(with-current-buffer gaplay-plylst-buffer
	  (setq kill-buffer-query-functions nil))
       (kill-buffer gaplay-plylst-buffer)))

  (gaplay-log "killed buffer %s in local" (buffer-name)) ;; debug
  )

(defun gaplay-buffer-p (&optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (and (eq major-mode 'gaplay-mode)
	 (local-variable-p 'gaplay-anchor-list))))

(defun gaplay-which-command (command)
  (catch 'gaplay-break
    (mapc
     #'(lambda (dir) 
	 (let ((path (expand-file-name command dir)))
	   (if (file-executable-p path) (throw 'gaplay-break path))))
     exec-path)
    nil))

(defun gaplay-mode ()
  "Major mode for interface to gaplay.py process\n
\\{gaplay-mode-map}
turning on gaplay-mode runs the hook `gaplay-mode-hook'."
  ;; (interactive)
  (unless (gaplay-buffer-p)
    (kill-all-local-variables)
    (buffer-disable-undo)  ;; not use undo
    (use-local-map gaplay-mode-map)
    (setq mode-name "gaplay"
	  major-mode 'gaplay-mode
	  buffer-read-only t
	  truncate-lines t ;; no wrap 
	  buffer-invisibility-spec t
	  line-spacing 0.15
	  )
    (set-buffer-multibyte t) ;; use multibyte

    ;; -- initialize buffer-local-variable (can customize) ---
    ;; volume
    (set (make-local-variable 'gaplay-player-gain) 0.8)
    ;; play mode
    (set (make-local-variable 'gaplay-loop-mode) nil)
    (set (make-local-variable 'gaplay-shuffle-mode) nil)
    ;; show/hide keybindings help
    (set (make-local-variable 'gaplay-keybindings-visible) t)

    ;; run hook
    (run-hooks 'gaplay-mode-hook)

    ;; initialize buffer-local-variable 
    (set (make-local-variable 'gaplay-process) nil) ;; player process
    (set (make-local-variable 'gaplay-anchor-list) nil)
    (set (make-local-variable 'gaplay-source) nil)
    (set (make-local-variable 'gaplay-boot-messages) nil)
    ;; current player info
    ;; (set (make-local-variable 'gaplay-player-gain) 0.8)
    (set (make-local-variable 'gaplay-player-ismute) nil)
    (set (make-local-variable 'gaplay-player-timeinfo) '(0 . -1))
    (set (make-local-variable 'gaplay-player-tags) nil)
    (set (make-local-variable 'gaplay-player-url) nil)
    (set (make-local-variable 'gaplay-player-state) nil)
    ;; `->> data-list'  response 
    (set (make-local-variable 'gaplay-player-list-response) nil)
    ;; timer
    (set (make-local-variable 'gaplay-message-timer) nil)
    ;; playlist buffer
    (set (make-local-variable 'gaplay-plylst-buffer) nil)

    (save-excursion
      ;; write template
      (gaplay-write-template)
      ;; write initial anchor
      (gaplay-render-current)
      )

    ;; set local kill-buffer-hook
    (make-local-hook 'kill-buffer-hook) ;; no need since 21.1
    (add-hook 'kill-buffer-hook 'gaplay-kill-buffer-handler nil t)
    ;; set local post-command-hook

    (random t) ;; set random seed. -- (better to use random* ??)

    ;; check runtime
    (let ((ehead #("Error:" 0 6 (face (highlight bold))))
	  (emsg
	   (cond ((not (file-regular-p gaplay-player-script))
		  (format "gaplay-player-script is not exists - %s"
			  gaplay-player-script))
		 ((not (gaplay-which-command gaplay-python-command))
		  (format "Python not found - `%s'"
			  gaplay-python-command))
		 (t nil))))
      (when emsg
	(save-excursion (gaplay-render-message (concat ehead " " emsg))
			(message (concat "Error: " emsg)))))
    ))

(defun gaplay-connect ()
  "Start gaplay.py process. Return new process."
  (when (processp gaplay-process)
    (delete-process gaplay-process)
    (setq gaplay-process nil))
  (let ((process-connection-type t) ;; use pty
	)
    (setq gaplay-boot-messages nil)
    (setq gaplay-process
	  (apply #'start-process
		 `("gaplay.py" ,(current-buffer)
		   ,gaplay-python-command  ,gaplay-player-script
		   . ,gaplay-player-script-options)))
    (set-process-coding-system gaplay-process 'utf-8-unix 
			       (or (cdr default-process-coding-system)
				   'no-conversion))
    ;; Set process filter function
    (set-process-filter 
     gaplay-process
     (lexical-let ((pending-data ""))
       #'(lambda (proc data)
	   (let ((dlst (split-string data "[\n\r]+"))
		 (pbuf (process-buffer proc)))
	     (if pbuf
		 (with-current-buffer pbuf
		   (if (eq proc gaplay-process)
		       (let ((responses nil))
			 (while dlst
			   (if (cdr dlst)
			       (let ((out (concat pending-data (car dlst))))
				 (if (not (string-equal out ""))
				     (setq responses (cons out responses)))
				 (setq pending-data ""))
			     (setq pending-data (concat pending-data (car dlst))))
			   (setq dlst (cdr dlst)))
			 (if responses
			     (gaplay-dispatch-response proc (nreverse responses)))
			 )
		     (gaplay-log "Discard response - %s" (concat pending-data data))
		     ))
	       (gaplay-log "WARNING: process-buffer is nil in filter - %s"
			   data))
	     ))))
			 
    ;; Set sentinel
    (set-process-sentinel
     gaplay-process
     #'(lambda (proc event)
	 (let ((pbuf (process-buffer proc))
	       (change (gaplay-trim (format "%s" event)))
	       (status (process-status proc))
	       (ecode (process-exit-status proc)))
	   (let ((isquit (or (eq status 'exit) (eq status 'signal) (null status) )))
	     (gaplay-log "Process %s sentinel comes, status=%s ecode=%d event=[%s]" 
			 proc status ecode change) ;; debug
	     (if (and (bufferp pbuf) (buffer-live-p pbuf))
		 (with-current-buffer pbuf
		   (cond
		    ((eq status 'stop)
		     (continue-process proc)
		     (gaplay-error-response "Catch SIGSTOP" t) ;; keep-connect
		     (run-at-time 1 nil
				  #'(lambda (prc) (interrupt-process prc)) proc)
		     )
		    ((and isquit (eq gaplay-process proc))
		     ;; When not recognizing QUIT command here 
		     ;;   When the quit command is dispatched, gaplay-process 
		     ;;   becomes unmatched.
		     (gaplay-log "Send quit command in process sentinel")
		     (save-excursion
		       (cond ((eq gaplay-player-state 'CONNECTING)
			      (gaplay-error-response
			       (format "process exited abnormally - %s"
				       (gaplay-string-join gaplay-boot-messages "\n")) t))
			     ((not (= ecode 0))
			      (gaplay-error-response
			       (format "process exited abnormally with code %d" ecode) t))
			     )
		       (gaplay-quit-response "")))
		    )
		   ))
	     ;; clean
	     (if isquit (progn (set-process-buffer proc nil)
			       (delete-process proc))) ;; not need?
	     ))))
  ))

(defun gaplay-disconnect (&optional interrupt)
  "Send quit command to gaplay-process and delete-process later."
  (when (processp gaplay-process)
    (let ((old-process gaplay-process)
	  (pstat (process-status gaplay-process)))
      (if (and pstat (not (eq pstat 'exit)))
	  (progn  (process-send-string gaplay-process "quit\n")
		  (if interrupt (interrupt-process gaplay-process)))
	(gaplay-log "WARNING: exited process in gaplay-disconnect"))
      (set-process-buffer old-process nil)
      (setq gaplay-process nil)
      (run-at-time 3 nil 
		   #'(lambda (proc)
		       (gaplay-log "Delete process from timer - %s %s"
				   proc (process-status proc))
		       (delete-process proc)) old-process)
      )))

(defun gaplay-get-buffer ()
  "Get gaplay buffer.
  if current-buffer is gaplay-plylst-buffer:
    return it's player-buffer
  elsif current-buffer is gaplay-mode :
    return current-buffer
  else:
     search gaplay-mode buffer,
     if no find at all, then return new gaplay buffer."
  (if (gaplay-plylst-buffer-p) gaplay-player-buffer
    (catch 'gaplay-break
      (mapc #'(lambda (buf)
		(if (gaplay-buffer-p buf)  (throw 'gaplay-break buf))
		) (cons (current-buffer) (buffer-list)))
      (let ((newbuf (generate-new-buffer gaplay-buffer-name)))
	(with-current-buffer newbuf (gaplay-mode))
	newbuf)
      )))

;; Note: current buffer must be gaplay-buffer or plylst-buffer
(defun gaplay-loop-mode-p ()
  (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			 gaplay-player-buffer)
    gaplay-loop-mode))

(defun gaplay-shuffle-mode-p ()
  (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			 gaplay-player-buffer)
    gaplay-shuffle-mode))

(defun gaplay (&optional url)
  "A GStreamer based audio player"
  (interactive)
  (switch-to-buffer (gaplay-get-buffer)))

(defun gaplay-send-rawcommand (command )
  "Debug command for gaplay.el"
  (interactive "sCommand> ")
  (let ((command (gaplay-trim command)))
    (if (and (not (string= command "")) gaplay-process)
	(progn (gaplay-log "Send raw command [%s]" command)
	       (process-send-string gaplay-process (concat command "\n"))))))

(defun gaplay-read-file/url (pfx &rest options)
  (let ((prompt-file (or (car (plist-get options :prompt)) "File or Directory: "))
	(prompt-url  (or (cadr (plist-get options :prompt)) "URL: ")))
    (if (consp pfx)
	(let ((url (gaplay-trim
		    (or (read-string prompt-url (car gaplay-read-url-history)
				     'gaplay-read-url-history) ""))))
	  (if (string= url "") nil 
		(concat (if (gaplay-url-p url) "" "http://") url)))
      (let ((fpath
	     (read-file-name prompt-file nil
			     (if (or (null (buffer-file-name))
				     (member
				      (downcase
				       (or (file-name-extension (buffer-file-name)) ""))
				      (append gaplay-playlist-extensions
					      gaplay-avfile-extensions))) nil
			       default-directory) t)))
	(if (string= (gaplay-trim fpath) "") nil
	  (if (plist-get options :expand)
	      (expand-file-name fpath) fpath))))))

(defun gaplay-ready-p ()
  (and gaplay-process gaplay-player-state))

(defun gaplay-loaded-p ()
  (and (gaplay-ready-p) 
       gaplay-source
       (not (memq gaplay-player-state '(CONNECTING LOADING))))
  )

(defun gaplay-source-path () (gaplay-get-alist :path gaplay-source))
(defun gaplay-source-shoutcast-p ()
  (eq (gaplay-get-alist :type gaplay-source) 'shoutcast))
(defun gaplay-source-add-plylst-p ()
  (gaplay-get-alist :add-plylst gaplay-source))
(defun gaplay-source-new-plylst-p ()
  (gaplay-get-alist :new-plylst gaplay-source))

(defun gaplay-load-source (&optional source)
  (let ((src (or source gaplay-source)))
    (if src
	(save-excursion
	  (setq gaplay-player-timeinfo '(0 . -1))
	  (setq gaplay-player-tags nil)
	  (setq gaplay-player-list-response nil)
	  (setq gaplay-source src)
	  (gaplay-disconnect)
	  (gaplay-connect)
	  (setq gaplay-player-state 'CONNECTING)
	  (gaplay-render-current)
	  (if (not (gaplay-url-file-p (gaplay-source-path)))
	      (let ((kdef (or (car (gaplay-key-descriptions 'gaplay-stop/interrupt))
			      "M-x gaplay-stop/interrupt")))
		(gaplay-render-message
		 (format "Type %s to stop the connection..." kdef))))
	  src)
      nil)))

(defun gaplay-switch-window/load (player-buffer &optional plylst-buffer)
  (let ((winbuf (window-buffer)))
    (cond ((eq winbuf player-buffer) nil)
	  ((eq winbuf (or plylst-buffer 
			   (with-current-buffer player-buffer gaplay-plylst-buffer)))
	   (display-buffer player-buffer))
	  (t (switch-to-buffer-other-window player-buffer)))))

(defun gaplay-load-next (&rest options)
  "Load next playlist entry.
   OPTIONS: (:loop BOOLEAN :shuffle BOOLEAN)
   Returns load path-info or nil
   current buffer must be gaplay-buffer"
  (if (bufferp gaplay-plylst-buffer)
      (let ((entry
	     (with-current-buffer gaplay-plylst-buffer
	       (gaplay-goto-next-plylst :move-marker t :show-marker t
					:loop (gaplay-loop-mode-p)
					:shuffle (gaplay-shuffle-mode-p)
					))))
	(if entry (gaplay-load-source `((:path . ,entry)))))
    nil))

(defun gaplay-load (&optional path add-plylst)
  "Load audio filepath or URL(when used with a `C-u' prefix) and 
begin to play it.\n
If PATH is a plain file:
  if the extension of PATH is .m3u / .pls :
    Load PATH as playlist and play the first song.
  else: 
    Simply play PATH.
else if PATH is directory:
    Add directory entries to the playlist, and play the first song.

In a Lisp program, PATH must not be nil"
  (interactive)
  (let* ((tramp-mode nil)
	 (loadpath
	  (or path
	      (gaplay-read-file/url
	       current-prefix-arg
	       :prompt (if add-plylst '("File or Directory to add: " "URL to add: ") nil)
	       :expand t))))
    (if loadpath
	(let ((embuf (gaplay-get-buffer)))
	  (with-current-buffer embuf
	    (if (gaplay-url-p loadpath)
		;; when URL
		(gaplay-load-source
		    `((:path . ,loadpath)
		      ,(cons (if add-plylst :add-plylst :new-plylst) t)))
	      (let ((ext (downcase (or (file-name-extension loadpath) ""))))
		(cond ((file-directory-p loadpath)
		       ;; load files in directory
		       (gaplay-load-entries (gaplay-read-dir-entries loadpath)
					    t add-plylst))
		      ((string= ext "m3u")
		       (gaplay-load-entries (gaplay-read-m3u-entries loadpath)
					    t add-plylst))
		      ((string= ext "pls")
		       (gaplay-load-entries (gaplay-read-pls-entries loadpath)
					    t add-plylst))
		      (t
		       (gaplay-load-source
			`((:path . ,loadpath)
			  ,(cons (if add-plylst :add-plylst :new-plylst) t))))))))
	  (gaplay-switch-window/load embuf)))))	
  
(defun gaplay-add (&optional path)
  "Add filepath or URL(when used with a `C-u' prefix) to playlist, 
and begin to play."
  (interactive) (gaplay-load path t))

(defun gaplay-load-url ()
  "Load URL and begin to play
Don't use this in Lisp programs; use `gaplay-load' instead."
  (interactive)
  (gaplay-load (or (gaplay-read-file/url '(4)) (error "Balnk URL"))))

(defun gaplay-add-url ()
  "Add URL to playlist, and begin to play
Don't use this in Lisp programs; use `gaplay-load' with 
ADD-PLYLST option instead."
  (interactive)
  (gaplay-load (or (gaplay-read-file/url '(4) :prompt '(nil "URL to add: ") )
		   (error "Balnk URL")) t))

(defun gaplay-shoutcast (&optional path add-plylst) 
  "Listen Shoutcast/Icecast music with given playlist PATH.
PATH must be `m3u' or `pls' file or URL(when used with a `C-u' prefix).
In a Lisp program, PATH must not be nil"
  (interactive)
  (let ((playlist
	 (or path (gaplay-read-file/url current-prefix-arg :expand t))))
    (if playlist
	(let ((embuf (gaplay-get-buffer)))
	  (with-current-buffer embuf
	    (gaplay-load-source
	     `((:path . ,playlist) (:type . shoutcast)
	       ,(cons (if add-plylst :add-plylst :new-plylst) t))))
	  (gaplay-switch-window/load embuf)))))

(defun gaplay-load-m3u (&optional path add-plylst)
  "Load m3u or pls playlist, and play first song."
  (interactive "fm3u filename: ")
  (let ((path (expand-file-name path)))
    (if (and (file-readable-p path) (file-regular-p path))
	(let ((pbuf (gaplay-get-buffer))
	      (ext (downcase (or (file-name-extension path) ""))))
	  (let ((read-entries (cond ((string= ext "m3u")
				     #'gaplay-read-m3u-entries)
				    ((or (string= ext "pls") (gaplay-plsfile-p path))
				     #'gaplay-read-pls-entries)
				    (t #'gaplay-read-m3u-entries))))
	    (with-current-buffer pbuf
	      (gaplay-load-entries (funcall read-entries path) t add-plylst)))
	  (gaplay-switch-window/load pbuf)))))

(defun gaplay-add-m3u (&optional path)
  "Add m3u or pls playlist, and play first song"
  (interactive "fm3u filename to add: ")
  (gaplay-load-m3u path t))

(defun gaplay-replay ()
  "Replay a song."
  (interactive)
  (if (gaplay-buffer-p (current-buffer))
      (if (gaplay-loaded-p)
	  ;; (process-send-string gaplay-process "stop\nplay\n")
	  (process-send-string gaplay-process "replay\n")
	(if gaplay-source (gaplay-load-source)))))

(defun gaplay-toggle-pause ()
  "Pause if playing, play otherwise."
  (interactive)
  (if (gaplay-buffer-p (current-buffer))
      (if (gaplay-loaded-p)
	  (process-send-string gaplay-process "pause\n")
	(if gaplay-source (gaplay-load-source)))))

(defun gaplay-quit ()
  (interactive "")
  (let ((buf (window-buffer)))
    (if (gaplay-buffer-p buf)
	(with-current-buffer buf
	  (gaplay-disconnect)
	  (set-buffer-modified-p nil) ;; suppress query
	  (kill-buffer buf)))
    ))

(defun gaplay-raw-stop ()
  "Debug command for gaplay.el"
  (interactive)
  (if (and (gaplay-buffer-p (current-buffer)) (gaplay-loaded-p))
      (process-send-string gaplay-process "stop\n")))

(defun gaplay-stop ()
  "Stop to play."
  (interactive)
  (when (and (gaplay-buffer-p (current-buffer)) (gaplay-loaded-p))
    (gaplay-disconnect)
    (setq gaplay-player-state nil)
    (setq gaplay-player-timeinfo '(0 . -1))
    (gaplay-render-current)))

(defun gaplay-stop/interrupt ()
  "Disconnect process with SIGINT"
  (interactive)
  (when (gaplay-buffer-p (current-buffer))
    (gaplay-disconnect t)
    (setq gaplay-player-state nil)
    (setq gaplay-player-timeinfo '(0 . -1))
    (gaplay-render-current)
    (if gaplay-source
	(save-excursion
	  (gaplay-render-message
	   (format "Disconnect %s" (gaplay-source-path)))))
    ))

(defun gaplay-up-gain (upvalue)
  (interactive "p")
  (when (or (gaplay-buffer-p) (gaplay-plylst-buffer-p))
    (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			   gaplay-player-buffer)
      (setq gaplay-player-gain
	    (max (min (+ gaplay-player-gain
			 (/ (or upvalue 1) 100.0)) 1.0) 0.0))
      (if (and (gaplay-loaded-p) (not gaplay-player-ismute))
	  (process-send-string gaplay-process
			       (format "gain %f\n" gaplay-player-gain))
	(save-excursion (gaplay-render-gain)))))
  )

(defun gaplay-down-gain (downvalue)
  (interactive "p")
  (gaplay-up-gain (- (or downvalue 1))))

(defun gaplay-gain/mute ()
  (if gaplay-player-ismute 0 gaplay-player-gain))

(defun gaplay-mute ()
  "toggle mute"
  (interactive)
  (when (gaplay-buffer-p (current-buffer))
    (setq gaplay-player-ismute (not gaplay-player-ismute))
    (if (gaplay-loaded-p)
	(process-send-string gaplay-process
			     (format "gain %f\n" (gaplay-gain/mute))))
    (save-excursion (gaplay-render-mute))))

(defun gaplay-toggle-loop ()
  "Turn repeat mode on or off."
  (interactive)
  (when (or (gaplay-buffer-p) (gaplay-plylst-buffer-p))
    (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			   gaplay-player-buffer)
      (setq gaplay-loop-mode (not gaplay-loop-mode))
      (save-excursion (gaplay-render-playmode))
      (message "Play mode: %s" (gaplay-playmode-string "normal")))))

(defun gaplay-toggle-shuffle ()
  "Turn shuffle mode on or off."
  (interactive)
  (when (or (gaplay-buffer-p) (gaplay-plylst-buffer-p))
    (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			   gaplay-player-buffer)
      (setq gaplay-shuffle-mode (not gaplay-shuffle-mode))
      (if (bufferp gaplay-plylst-buffer)
	  (with-current-buffer gaplay-plylst-buffer (gaplay-clear-order-all)))
      (save-excursion (gaplay-render-playmode))
      (message "Play mode: %s" (gaplay-playmode-string "normal")))))

(defun gaplay-seek (seconds)
  (if (and (gaplay-loaded-p) (not (eq gaplay-player-state 'IDLE)))
      (process-send-string gaplay-process (format "skip %d\n" seconds))
    ))

(defun gaplay-seek-forward ()
  (interactive)
  (when (or (gaplay-buffer-p) (gaplay-plylst-buffer-p))
    (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			   gaplay-player-buffer)
      (gaplay-seek gaplay-seeking-seconds))))

(defun gaplay-seek-backward ()
  (interactive)
  (when (or (gaplay-buffer-p) (gaplay-plylst-buffer-p))
    (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			   gaplay-player-buffer)
      (gaplay-seek (- gaplay-seeking-seconds)))))

(defun gaplay-seek-fforward ()
  (interactive)
  (when (or (gaplay-buffer-p) (gaplay-plylst-buffer-p))
    (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			   gaplay-player-buffer)
      (gaplay-seek (* 4 gaplay-seeking-seconds)))))

(defun gaplay-seek-bbackward ()
  (interactive)
  (when (or (gaplay-buffer-p) (gaplay-plylst-buffer-p))
    (with-current-buffer (if (gaplay-buffer-p) (current-buffer)
			   gaplay-player-buffer)
    (gaplay-seek (- (* 4 gaplay-seeking-seconds))))))

(defun gaplay-jump ()
  "Jump to TIMESTRING position
TIMESTRING: mm:ss or hh:mm:ss"
  (interactive)
  (when (gaplay-buffer-p)
    (cond ((or (not (gaplay-loaded-p))
	       (eq gaplay-player-state 'IDLE))
	   (message "Can't jump, while not playing"))
	  ((<= (cdr gaplay-player-timeinfo) 0) (message "Can't jump"))
	  (t
	   (let ((seconds (gaplay-str2sec (read-string "Jump to (mm:ss): ")))
		 (duration (cdr gaplay-player-timeinfo)))
	     (if (>= seconds 0)
		 (process-send-string gaplay-process
				      (format "jump %d\n" (min seconds duration)))))
	   ))))

(defun gaplay-jump/click (ev)
  (interactive "e")
  (if (and (gaplay-buffer-p)
	   (gaplay-loaded-p) (not (eq gaplay-player-state 'IDLE))
	   (> (cdr gaplay-player-timeinfo) 0))
      (let ((bar-length (+ gaplay-timeline-length (length gaplay-timeline-bar)))
	    (duration (cdr gaplay-player-timeinfo))
	    (boffs (-
		    ;; (posn-point (event-start ev))
		    (progn (mouse-set-point ev) (point))
		    (gaplay-anchor:start (gaplay-find-anchor 'timeline)))))
	(if (>= boffs 0)
	    (let ((sec (min (* boffs (/ (float duration) bar-length)) duration)))
	      (process-send-string gaplay-process (format "jump %d\n" (round sec)))
	      ;; (goto-char (gaplay-anchor:start (gaplay-find-anchor 'time)))
	      )))
    ))

(defun gaplay-show-plylst ()
  "Toggle show/hide gaplay playlist buffer"
  (interactive)
  (when (gaplay-buffer-p (current-buffer))
    (if (and (bufferp gaplay-plylst-buffer)
	     (get-buffer-window gaplay-plylst-buffer))
	(delete-windows-on gaplay-plylst-buffer t)
      (let ((lstbuf (gaplay-get-plylst-buffer)))
	(display-buffer lstbuf)
	(with-current-buffer lstbuf
	  (if (markerp gaplay-play-marker)
	      (gaplay-show-point gaplay-play-marker))))
      )))

(defun gaplay-shrink-player ()
  "Shrink or enlarge player window if possible."
  (interactive)
  (if (and (eq (window-buffer) (current-buffer)) (gaplay-buffer-p))
      (let* ((full-height #'(lambda ()
			      (save-window-excursion (delete-other-windows)
						     (window-height))))
	     ;; (full-height #'(lambda () (window-height (frame-root-window))))
	     (full-height-p 
	      (if (fboundp 'window-full-height-p) #'window-full-height-p
		#'(lambda () (= (window-height) (funcall full-height)))))
	     (shrink-height #'(lambda ()
				(max window-min-height gaplay-shrink-window-height)))
	     (adjust-point #'(lambda ()
			       (when (gaplay-buffer-p)
				 (goto-char
				  (gaplay-anchor:start (gaplay-find-anchor 'time)))
				 (set-window-start (selected-window) (point)))))
	     (shrink #'(lambda ()
			 (let ((delta (- (window-height)
					 (funcall shrink-height))))
			   (when (and (> delta 0) (window-safely-shrinkable-p))
			     (shrink-window delta)
			     (with-current-buffer (window-buffer) (funcall adjust-point)))
			   )))
	     (enlarge #'(lambda ()
			  (let ((delta
				 (- (funcall full-height) (funcall shrink-height)
				    (window-height))))
			    (when (and (> delta 0) (window-safely-shrinkable-p))
			      (enlarge-window delta)))))
	     )
	(cond ((funcall full-height-p) 
	       (split-window-vertically (funcall shrink-height))
	       (with-current-buffer (window-buffer) (funcall adjust-point))
	       (display-buffer
		(or (and (bufferp gaplay-plylst-buffer)
			 (get-buffer-window gaplay-plylst-buffer)
			 (other-buffer))
		    (gaplay-get-plylst-buffer))   t))
	      ((> (window-height) (funcall shrink-height))
	       (funcall shrink))
	      (t (funcall enlarge))))))

(defun gaplay-key-descriptions (fsymbol &optional kmaps)
  "Return key description list binding FSYMBOL"
  (mapcar #'key-description 
	  (where-is-internal fsymbol (or kmaps (list gaplay-mode-map)))))

;; ******** dispatch response from player process *******
;; *  current-buffer must be gaplay-mode
;; *  Not with old-process message
;; ******************************************************
(defun gaplay-quit-response (arg)
  (setq gaplay-process nil)
  (setq gaplay-player-state nil)
  (gaplay-render-state))

(defun gaplay-ready-response (arg)
  (if (and (eq gaplay-player-state 'CONNECTING) gaplay-source)
      (let ((path (gaplay-source-path)))
	(process-send-string
	 gaplay-process
	 (format (cond ((gaplay-source-shoutcast-p) 
			"gain %f\nload-shoutcast 1 %s\n")
		       ((gaplay-url-http-p path) "gain %f\nload-http %s\n")
		       (t "gain %f\nload %s\n"))
		 (gaplay-gain/mute) path))
	(setq gaplay-player-state 'LOADING))
    (setq gaplay-player-state 'IDLE))
  (gaplay-render-state))

(defun gaplay-eos-response (arg)
  (let ((current-state gaplay-player-state))
    (gaplay-disconnect)
    (setq gaplay-player-state nil)
    (let ((pos (car gaplay-player-timeinfo))
	  (dur (cdr gaplay-player-timeinfo)))
      (when (and (> dur 0) (> pos 0) (> (/ (float pos) (float dur)) 0.9))
	;; fake last timeline
	(setq gaplay-player-timeinfo (cons dur dur))
	(gaplay-render-timeinfo)))
    (gaplay-log "End of stream - %s" arg)
    (gaplay-render-message "End of the music")
    (gaplay-render-state)
    (if (not (memq gaplay-player-state '(CONNECTING LOADING)))
	(gaplay-load-next))
    ))

(defun gaplay-error-response (arg &optional keep-connect)
  (unless keep-connect
    (when (eq gaplay-player-state 'LOADING)
      (setq gaplay-source nil)
      (gaplay-render-source-name))
    (gaplay-disconnect)
    (setq gaplay-player-state nil)
    )
  (gaplay-log "Error: %s" arg)
  (gaplay-render-message
   (format "%s %s" #("Error:" 0 6 (face (highlight bold))) arg))
  (gaplay-render-state)
  (unless keep-connect (sit-for 2) (gaplay-load-next)))

(defun gaplay-warning-response (arg)
  (gaplay-log "Warning: %s" arg)
  (gaplay-render-message
   (format "%s %s" #("Warning:" 0 8 (face (bold))) arg) 10))

(defun gaplay-play-response (arg)
  (unless (eq gaplay-player-state 'PLAYING)
    (setq gaplay-player-state 'PLAYING)
    (gaplay-render-state))
  )

(defun gaplay-pause-response (arg)
  (unless (eq gaplay-player-state 'PAUSED)
    (setq gaplay-player-state 'PAUSED)
    (gaplay-render-state))
  )

(defun gaplay-stop-response (arg)
  (if (and gaplay-player-state (not (eq gaplay-player-state 'IDLE)))
      (progn (setq gaplay-player-state 'IDLE)
	     (gaplay-render-state))))

(defun gaplay-load-response (arg)
  (gaplay-play-response "")
  (setq gaplay-player-url arg)
  (when (or (gaplay-source-add-plylst-p) (gaplay-source-new-plylst-p))
    (gaplay-add-plylst-entry
     (if (gaplay-source-shoutcast-p) gaplay-player-url (gaplay-source-path))
     :move-marker t :show-marker t :new (gaplay-source-new-plylst-p))
    (setq gaplay-source
	  (gaplay-delete-alist :new-plylst
			       (gaplay-delete-alist :add-plylst gaplay-source)))
    (when (gaplay-shuffle-mode-p)
      (with-current-buffer gaplay-plylst-buffer
	(gaplay-clear-order-all) (gaplay-shuffle-message)
	(gaplay-set-order 1 (marker-position gaplay-play-marker))))
    )
  (gaplay-log "Loaded %S" gaplay-player-url)
  (gaplay-render-message
   (format "Load %s" 
	   (decode-coding-string
	    (url-unhex-string (string-as-unibyte gaplay-player-url)) ;; emacs22
	    ;; (url-unhex-string gaplay-player-url) ;; emacs23
	    'utf-8)) 10)
  )

(defun gaplay-time-response (arg)
  (if (and arg (string-match "\\([-:0-9]+\\) */ *\\([-:0-9]+\\)" arg))
      (let ((spos (match-string 1 arg)) (sdur (match-string 2 arg)))
	(let ((position (gaplay-str2sec spos))
	      (duration (gaplay-str2sec sdur)))
	  (if (and (integerp position) (integerp duration))
	      (let ((tminfo (cons position duration)))
		(unless (equal tminfo gaplay-player-timeinfo)
		  (setq gaplay-player-timeinfo tminfo)
		  (gaplay-render-timeinfo))))))))

(defun gaplay-gain-response (arg)
  (let ((val (gaplay-string-to-number arg)))
    (if val
	(unless gaplay-player-ismute
	  (setq gaplay-player-gain val)
	  (gaplay-render-gain))
      (gaplay-log "WARNING: `gain' response has not numerical value - %s"
		  arg))))

(defun gaplay-tag-response (arg)
  (if (string-match "\\([-_A-Za-z0-9]+\\)[ \t]*" arg)
      (let ((bitrate-keys '(bitrate maximum-bitrate minimum-bitrate
				    nominal-bitrate))
	    (etype (match-string 1 arg))
	    (slst (split-string (substring arg (match-end 0)) "=")))
	(if (cdr slst)
	    (let ((key (intern (car slst)))
		  (value (gaplay-string-join (cdr slst) "=")))
	      (if (memq key bitrate-keys)
		  ;; add audio/video key to bitrate-tag
		  ;; e.g. minimum-bitrate -> video-minimum-bitrate
		  (setq key
			(cond ((string= etype "A")
			       (intern (concat "audio-" (symbol-name key))))
			      ((string= etype "V")
			       (intern (concat "video-" (symbol-name key))))
			      (t key))))
	      (setq gaplay-player-tags
		    (gaplay-add-alist key value gaplay-player-tags))
	      (gaplay-log "tags: %s" gaplay-player-tags)
	      (gaplay-render-tag key))
	  (gaplay-log "WARNING: illegal tag - %s" arg)
	  ))
    (gaplay-log "WARNING: illegal tag - %s" arg)))

(defun gaplay-cap-response (arg)
  (let ((case-fold-search t))
    (if (string-match "^audio/" arg)
	(if (string-match "rate=\\([-+.0-9]+\\)" arg)
	    (progn
	      (setq gaplay-player-tags
		    (gaplay-add-alist '*sample-rate* (match-string 1 arg)
				      gaplay-player-tags))
	      ;; (gaplay-log "tags %s" gaplay-player-tags)
	      (gaplay-render-tag '*sample-rate*))))))

(defun gaplay-playlist-begin-response (arg)
  (let ((case-fold-search t))
    (if (string-match "\\(pls\\|m3u\\)[ \t]+" arg)
	(let ((type (match-string 1 arg))
	      (url (substring arg (match-end 0))))
	  (if (and (eq gaplay-player-state 'LOADING)
		   (string= (gaplay-source-path) url))
	      (setq gaplay-player-list-response `((:type playlist :url ,url)))
	    (gaplay-log
	     "WARNING: Illegal PLAYLIST-BEGIN response - %s state=%s"
	     arg gaplay-player-state))))))

(defun gaplay-playlist-end-response (arg)
  (if (and (eq (plist-get (car gaplay-player-list-response) :type) 'playlist)
	   (eq gaplay-player-state 'LOADING))
      (let ((url (plist-get (car gaplay-player-list-response) :url))
	    (srcpath (gaplay-source-path))
	    (entries
	     (nreverse
	      (gaplay-collect*
	       #'(lambda (rsp)
		   (let ((case-fold-search t))
		     (if (string-match "[0-9]+L?[ \t]+path[ \t]+" rsp)
			 (substring rsp (match-end 0)) nil)))
	      (cdr gaplay-player-list-response)))))
	(setq gaplay-player-list-response nil)
	(if entries
	    (if (or (gaplay-source-new-plylst-p) (gaplay-source-add-plylst-p))
		(progn
		  (gaplay-load-entries entries t (gaplay-source-add-plylst-p))
		  (setq gaplay-source
			(gaplay-delete-alist
			 :new-plylst
			 (gaplay-delete-alist :add-plylst gaplay-source))))
	      (with-current-buffer (gaplay-get-plylst-buffer)
		(let ((mpnt
		       (and (markerp gaplay-play-marker)
			    (marker-position gaplay-play-marker)
			    (gaplay-plylst-pos/point gaplay-play-marker))))
		  (if mpnt
		      (let ((mentry (gaplay-line-content mpnt))
			    (addpos (save-excursion (goto-char mpnt)
						    (forward-line) (point))))
			(gaplay-load-entries entries t addpos)
			(if (string= mentry srcpath)
			    (gaplay-del-plylst-entry-1 mpnt)
			  (gaplay-log "WARNING: marker moved - playlist-end-response"))
			)
		    (progn (gaplay-log
			    "WARNING: marker is not exist - playlist-end-response")
			   (gaplay-load-entries entries t t))))))
	  ;; No entries
	  (gaplay-error-response (format "Empty playlist - %s" srcpath))
	  ))
    (progn
      (setq gaplay-player-list-response nil)
      (gaplay-log "WARNING: Illegal PLAYLIST-END response - %s state=%s"
		  arg gaplay-player-state))))


(defun gaplay-data-response (arg)
  (if (consp gaplay-player-list-response)
      (setq gaplay-player-list-response
	    (cons (car gaplay-player-list-response)
		  (cons arg (cdr gaplay-player-list-response))))
    (gaplay-log "WARNING: Illegal DATA response")))

(defun gaplay-dispatch-response (proc raw-responses)
  (let ((pntsv (point)) (restore-point nil)
	(responses
	 (gaplay-collect*
	  #'(lambda (resp)
	      (if (string-match "^->\\([A-Za-z_0-9->]+\\)[ \t]*" resp)
		  (cons (match-string 1 resp) (substring resp (match-end 0)))
		(progn
		  (if (and (eq gaplay-player-state 'CONNECTING)
			   (eq proc gaplay-process) ;; not-need
			   )
		      ;; Add process booting message
		      (setq gaplay-boot-messages (cons resp gaplay-boot-messages)))
		  (gaplay-log "Discard non-header response - %s" resp)
		  nil))) raw-responses)))
    ;; (gaplay-log "dispatch response - %s" responses) 
    (save-excursion
      (while responses
	(let ((header (upcase (car (car responses))))
	      (trailer (cdr (car responses))))
	  (cond
	   ((or (string= header "T") (string= header "SEEK"))
	    (gaplay-time-response trailer) (setq restore-point t))
	   ((string= header "PLAY") (gaplay-play-response trailer))
	   ((string= header "PAUSE") (gaplay-pause-response trailer))
	   ((string= header "GAIN") (gaplay-gain-response trailer))
	   ((string= header "TAG") (gaplay-tag-response trailer))
	   ((string= header "CAP") (gaplay-cap-response trailer))
	   ((string= header "STOP") (gaplay-stop-response trailer))
	   ((string= header "LOAD") (gaplay-load-response trailer))
	   ((string= header "QUIT") (gaplay-quit-response trailer))
	   ((string= header "READY") (gaplay-ready-response trailer))
	   ((string= header ">") (gaplay-data-response trailer))
	   ((string= header "PLAYLIST-BEGIN") 
	    (gaplay-playlist-begin-response trailer))
	   ((string= header "PLAYLIST-END") 
	    (gaplay-playlist-end-response trailer))
	   ((string= header "ERROR") (gaplay-error-response trailer))
	   ((string= header "EOS") (gaplay-eos-response trailer))
	   ((string= header "WARNING") (gaplay-warning-response trailer))
	   (t (gaplay-log "Unsupport response header - %s " header))))
	;; check gaplay-process == proc
	(setq responses (if (eq proc gaplay-process) (cdr responses) 
			  (progn
			    (mapc #'(lambda (rsp)
				      (gaplay-log "Discard oldproc response - %s"
						  rsp)) (cdr responses))
			    nil)))
	))
    (if restore-point
	(let ((tmline (gaplay-find-anchor 'timeline)))
	  (if (and (<= (gaplay-anchor:start tmline)  pntsv)
		   (< pntsv (gaplay-anchor:end tmline)))
	      (goto-char pntsv))))
    ))
     



;; ******** display functions ****************************
(defun gaplay-anchor:new (name &rest options)
  (list name
	(cons :overlay
	      (make-overlay (or (plist-get options :start) (point))
			    (or (plist-get options :end) (point))
			    (or (plist-get options :buffer) (current-buffer))
			    nil nil))
	(cons :format  (or (plist-get options :format) "%s"))
	(cons :fill (plist-get options :fill))
	))
(defun gaplay-anchor:name (anchor) (car anchor))
(defun gaplay-anchor:get (anchor key &optional fallback)
  (gaplay-get-alist key (cdr anchor) fallback))
(defun gaplay-anchor:set (anchor key value)
  (rplacd anchor (gaplay-add-alist key value (cdr anchor))))

(defun gaplay-anchor:overlay (anchor)
  (gaplay-anchor:get anchor :overlay))
(defun gaplay-anchor:overlay! (anchor ovl)
  (gaplay-anchor:set anchor :overlay ovl))
(defun gaplay-anchor:start (anchor)
  (overlay-start (gaplay-anchor:overlay anchor)))
(defun gaplay-anchor:end (anchor)
  (overlay-end (gaplay-anchor:overlay anchor)))
(defun gaplay-anchor:format (anchor)
  (gaplay-anchor:get anchor :format "%s"))
(defun gaplay-anchor:format! (anchor fmt)
  (gaplay-anchor:set anchor :format fmt))

(defun gaplay-anchor:overlay-put (anchor prop value)
  (overlay-put (gaplay-anchor:overlay anchor) prop value))
(defun gaplay-anchor:advance! (anchor front-advance rear-advance)
  (let ((new-ovl (make-overlay 1 1 nil front-advance rear-advance))
	(old-ovl (gaplay-anchor:overlay anchor)))
    (move-overlay new-ovl (overlay-start old-ovl)
		  (overlay-end old-ovl) (overlay-buffer old-ovl))
    (delete-overlay old-ovl)
    (gaplay-anchor:overlay! anchor new-ovl)
    new-ovl))

(defun gaplay-anchor:clear (anchor)
  (let ((ovl (gaplay-anchor:overlay anchor)))
    (if (overlayp ovl) (delete-overlay ovl))
    (rplacd anchor nil)
    anchor))

(defun gaplay-anchor:face! (anchor facelist)
  (gaplay-anchor:overlay-put anchor 'face facelist))

(defun gaplay-anchor:text (anchor &optional no-properties)
  "Return text string of anchor's overlay"
  (let ((overlay (gaplay-anchor:overlay anchor)))
    (with-current-buffer (overlay-buffer overlay)
      (funcall (if no-properties #'buffer-substring-no-properties
		 #'buffer-substring)
	       (max (overlay-start overlay) (point-min))
	       (min (overlay-end overlay) (point-max))))))
  
(defun gaplay-anchor:write (anchor &rest args)
  (let ((overlay (gaplay-anchor:overlay anchor))
	(fill (gaplay-anchor:get anchor :fill)))
    (with-current-buffer (overlay-buffer overlay)
      (let ((text (apply #'format (cons (gaplay-anchor:format anchor) args))))
	(if (not (equal-including-properties
		  (buffer-substring (max (overlay-start overlay) (point-min))
				    (min (overlay-end overlay) (point-max)))
		  text))
	    (let ((buffer-read-only nil))
	      (goto-char (overlay-start overlay))
	      (delete-region (overlay-start overlay) (overlay-end overlay))
	      (insert text)
	      (if (numberp fill) (gaplay-anchor-fill overlay fill)))
	  )))))

(defun gaplay-add-anchor (anchor)
  (setq gaplay-anchor-list (cons anchor gaplay-anchor-list)))
  
(defun gaplay-find-anchor (name)
  (find-if
   #'(lambda (anchor) (eq (gaplay-anchor:name anchor) name))
   gaplay-anchor-list))

(defun gaplay-anchor-fill (anchor &optional filcol)
  (save-excursion
    (let ((ovl (if (overlayp anchor) anchor (gaplay-anchor:overlay anchor))))
      (let ((s (overlay-start ovl)) (e (overlay-end ovl)))
	(let ((ind (progn (goto-char s) (current-column))))
	  (let ((fill-column (or filcol fill-column))
		(left-margin ind) (buffer-read-only nil)
		)
            ;; (fill-region-as-paragraph s e)
            (fill-region s e)
	    ))))))

(defun gaplay-write-template ()
  (let ((buffer-read-only nil))
    ;; delete previous overlay
    (mapc #'(lambda (anchor) (gaplay-anchor:clear anchor))
	  gaplay-anchor-list)
    
    (erase-buffer)
    (insert "             ")
    (let ((header "gst Audio Player"))
      (add-text-properties 0 (length header) '(face (:height 1.5)) header)
      (insert header))

    (insert "           ")
    (gaplay-add-anchor (gaplay-anchor:new 'playmode :format "%21s"))
    (insert "\n")

    (insert "             ")
    (gaplay-add-anchor (gaplay-anchor:new 'title :format "%s"))
    ;; (insert "   ")
    ;; (gaplay-add-anchor (gaplay-anchor:new 'artist :format "%s"))
    (insert "\n")
    (insert "             ")
    (gaplay-add-anchor (gaplay-anchor:new 'album :format "%s"))
    (insert "\n")

    (insert "  " #("Time" 0 4 (face underline)) ":" )
    (gaplay-add-anchor (gaplay-anchor:new 'time))
    (insert " [")
    (gaplay-add-anchor (gaplay-anchor:new 'timeline))
    (insert "]")
    (insert " ")
    (gaplay-add-anchor (gaplay-anchor:new 'duration))
    (insert "\n")

    (insert "  " #("Volume" 0 6 (face underline)) ":")
    (gaplay-add-anchor (gaplay-anchor:new 'gain :format "%d%%"))
    (insert " ")
    (gaplay-add-anchor (gaplay-anchor:new 'mute))
    (insert "\n")

    (insert "  " #("State" 0 5 (face underline)) " :")
    (gaplay-add-anchor (gaplay-anchor:new 'state :format "%-10s"))
    (insert "\n\n")

    (insert "  " #("Source" 0 6 (face underline)) ": ")
    (gaplay-add-anchor (gaplay-anchor:new 'source))
    (insert "\n")

    ;; audio info
    (insert "          ")
    (gaplay-add-anchor (gaplay-anchor:new 'audio-info))
    (insert " ")
    (gaplay-add-anchor (gaplay-anchor:new 'channel-mode " %s "))
    (insert "\n\n")

    (insert "          ")
    (gaplay-add-anchor (gaplay-anchor:new 'message :format "%s" :fill 72 ))
    (insert "\n\n")

    (insert "  ")
    (gaplay-add-anchor (gaplay-anchor:new 'keybind-title))
    (insert "\n")
    (gaplay-add-anchor (gaplay-anchor:new 'keybind))
    (insert "\n")

    (goto-char (point-min))

    ;; Set all anchor's rear-advance to true 
    (mapc #'(lambda (anchor) (gaplay-anchor:advance! anchor nil t))
	  gaplay-anchor-list)

    ;; set face playmode anchor
    (gaplay-anchor:face! (gaplay-find-anchor 'playmode) '((:height 0.8)))
    ;; set face status anchor
    (gaplay-anchor:face! (gaplay-find-anchor 'state) '(bold (:height 0.8)))
    ;; set face source anchor
    (gaplay-anchor:face! (gaplay-find-anchor 'source) '((:height 0.8)))

    ;; set face message anchor
    ;; (gaplay-anchor:face! (gaplay-find-anchor 'message) '(highlight))
    (if (and (display-graphic-p)
	     (face-italic-p 'italic) (not (face-underline-p 'italic)))
	(gaplay-anchor:face! (gaplay-find-anchor 'message) '(italic)))

    ;; set face timeline anchor
    (gaplay-anchor:face! (gaplay-find-anchor 'timeline) '(underline))
    ;; set keymap to timeline anchor
    (gaplay-anchor:overlay-put (gaplay-find-anchor 'timeline)
			       'local-map
			       (let ((kmap (make-sparse-keymap)))
				 (set-keymap-parent kmap gaplay-mode-map)
				 (define-key kmap [mouse-1] 'gaplay-jump/click)
				 kmap))

    ;; set invisible and face mute anchor
    (let ((anc (gaplay-find-anchor 'mute)))
      (gaplay-anchor:overlay-put anc 'invisible t)
      (gaplay-anchor:face! anc '(:inverse-video t :height 0.9))
      (gaplay-anchor:write anc " mute "))

    ;; set face title anchor
    (gaplay-anchor:face! (gaplay-find-anchor 'title) '(bold))
    ;; set face stereo anchor
    ;; (gaplay-anchor:face! (gaplay-find-anchor 'stereo) '(bold-italic))

    ;; set face keybind anchor
    (gaplay-anchor:face! (gaplay-find-anchor 'keybind-title) '(underline))
    (gaplay-anchor:face! (gaplay-find-anchor 'keybind) '((:height 0.86)))
    (gaplay-show-keybind 'not-toggle)
    ))

;; Display current all anchors with current timeline, volume, playing-satus, 
;; playfile, and audioinfo value.
(defun gaplay-render-current ()
  (save-excursion
    (let ((buffer-read-only nil))
      (gaplay-render-gain) (gaplay-render-mute)
      (gaplay-render-state) (gaplay-render-playmode)
      (gaplay-render-timeinfo)
      (gaplay-render-source-name)
      (gaplay-render-tag)
      (gaplay-render-message "")
      (gaplay-render-keybind)
      )))

(defun gaplay-render-gain (&optional gain)
  (let ((gain (or gain gaplay-player-gain 0)))
    (gaplay-anchor:write (gaplay-find-anchor 'gain) (round (* gain 100)))))

(defun gaplay-render-mute ()
  (gaplay-anchor:overlay-put (gaplay-find-anchor 'mute) 'invisible 
			     (not gaplay-player-ismute)))

(defun gaplay-render-state (&optional state)
  (gaplay-anchor:write (gaplay-find-anchor 'state)
		       (or state gaplay-player-state "")))

(defun gaplay-playmode-string (&optional plain)
  (if gaplay-loop-mode
      (if gaplay-shuffle-mode "(Shuffle&Repeat mode)" "(Repeat mode)")
    (if gaplay-shuffle-mode "(Shuffle mode)" (or plain ""))))

(defun gaplay-render-playmode ()
  (gaplay-anchor:write
   (gaplay-find-anchor 'playmode) (gaplay-playmode-string)))

(defun gaplay-timeline-string (position duration)
  (let ((bar-length (+ gaplay-timeline-length (length gaplay-timeline-bar))))
    (let ((bar-pos ;; left edge position of bar
	   (cond ((> position 0)
		  (if (> duration 0)
		      (min
		       (max (round (/ (* position gaplay-timeline-length) duration)) 0)
		       gaplay-timeline-length)  0))
		 ((< position 0) (if (> duration 0) 0 gaplay-timeline-length))
		 (t 0))))
      (concat (make-string bar-pos gaplay-timeline-left)
	      gaplay-timeline-bar
	      (make-string (- gaplay-timeline-length bar-pos)
			   gaplay-timeline-right)))))

(defun gaplay-render-timeinfo (&optional time-pair)
  (let ((position (or (car time-pair) (car gaplay-player-timeinfo)))
	(duration (or (cdr time-pair) (cdr gaplay-player-timeinfo))))
    (let ((s-position (if (>= position 0) (gaplay-sec2str position) "  :  "))
	  (s-duration (if (> duration 0) (gaplay-sec2str duration) "")))
      (gaplay-anchor:write (gaplay-find-anchor 'time) s-position)
      (gaplay-anchor:write (gaplay-find-anchor 'duration) s-duration)
      (gaplay-anchor:write (gaplay-find-anchor 'timeline)
			   (gaplay-timeline-string position duration))
      )))

(defun gaplay-render-source-name ()
  (let ((text
	 (if gaplay-source
	     (let ((srcpath (gaplay-source-path)))
	       (if (gaplay-url-p srcpath) srcpath
		 (file-name-nondirectory srcpath)))
	   "none"))
	(anchor (gaplay-find-anchor 'source)))
    (gaplay-anchor:face! anchor
			 (if (> (string-width text) 72) '((:height 0.85))
			   '((:height 1.0))))
    (gaplay-anchor:write anchor text)))
		       
(defun gaplay-tag-to-title ()
  (gaplay-string-join
   (delete nil
	   (list
	    (gaplay-get-alist 'artist gaplay-player-tags nil)
	    (gaplay-get-alist 'title gaplay-player-tags nil))) " - "))

(defun gaplay-tag-to-bitrate ()
  "Convert gaplay-player-tags to a bitrate string.
If no bitrate data return nil"
  (let ((has-video (gaplay-get-alist 'video-codec gaplay-player-tags))
	(find-alist
	 #'(lambda (keys)
	     (car (delete nil (mapcar
			       #'(lambda (k)
				   (gaplay-string-to-number
				    (gaplay-get-alist k gaplay-player-tags "")))
			       keys)))))
	)
    (let ((rate (funcall
		 find-alist
		 (if has-video '(audio-bitrate audio-maximum-bitrate audio-nominal-bitrate)
		   '(audio-bitrate bitrate
				   audio-maximum-bitrate maximum-bitrate
				   audio-nominal-bitrate nominal-bitrate)))))
      (if rate 
	  (if (>= rate 1000) (format "%dkb/s" (round (/ rate 1000.0)))
		   (format "%db/s" (round rate))) nil))))

(defun gaplay-tag-to-audioinfo ()
  (let ((bps (gaplay-tag-to-bitrate))
	(sample-rate
	 (gaplay-string-to-number
	  (gaplay-get-alist '*sample-rate* gaplay-player-tags ""))))
    (let ((text
	   (gaplay-string-join
	    (delete nil
		    (list 
		     (gaplay-get-alist 'audio-codec gaplay-player-tags nil)
		     (and sample-rate (format "%dHz" sample-rate))
		     bps
		     (let ((mode
			    (gaplay-get-alist 'channel-mode gaplay-player-tags nil)))
		       (if mode (upcase mode) nil))))
	    " ")))
      (if (string= text "") "" (concat "(" text ")")))))

(defun gaplay-render-tag (&optional last-tagkey)
  ;; render 'title anchor
  (if (or (null last-tagkey) (memq last-tagkey '(title artist)))
      (gaplay-anchor:write (gaplay-find-anchor 'title) (gaplay-tag-to-title)))

  ;; render 'album anchor 
  (if (or (null last-tagkey) (memq last-tagkey '(album organization)))
      (gaplay-anchor:write (gaplay-find-anchor 'album)
			   (or (gaplay-get-alist 'album gaplay-player-tags nil)
			       (gaplay-get-alist 'organization gaplay-player-tags
						 ""))))
  ;; render 'audio-info anchor
  (if (or (null last-tagkey)
	  (memq last-tagkey
		'(bitrate audio-bitrate audio-maximum-bitrate maximum-bitrate
			  audio-nominal-bitrate nominal-bitrate
			  audio-codec *sample-rate* channel-mode video-codec)))
      (gaplay-anchor:write (gaplay-find-anchor 'audio-info)
			   (gaplay-tag-to-audioinfo)))

  ;; render source anchor with location=xxx tag
  (if (eq last-tagkey 'location) ;; rendering only when location tag comes
      (let ((loc (gaplay-trim (gaplay-get-alist 'location gaplay-player-tags ""))))
	(if (not (string= loc ""))
	    (gaplay-anchor:write (gaplay-find-anchor 'source) loc))))
  )

(defun gaplay-render-message (msg &optional timeout is-restore)
  (let ((anchor (gaplay-find-anchor 'message)))
    (let ((restore-text (and timeout is-restore (gaplay-anchor:text anchor))))
      (gaplay-anchor:write anchor msg)
      (if timeout
	  (let ((tmout-text (gaplay-anchor:text anchor t)))
	    (if (timerp gaplay-message-timer) (cancel-timer gaplay-message-timer))
	    (setq gaplay-message-timer
		  (run-at-time
		   timeout nil
		   #'(lambda (buffer tmoutstr clrstr)
		       (with-current-buffer buffer
			 (let ((anchor (gaplay-find-anchor 'message)))
			   (setq gaplay-message-timer nil)
			   (save-excursion
			     (if (string= tmoutstr (gaplay-anchor:text anchor t))
				 (gaplay-anchor:write anchor clrstr))))))
		   (current-buffer) tmout-text (or restore-text "")))
	    )
	))))
(defun gaplay-message-test (text)
  "Debug command for gaplay.el"
  (interactive "sMessage: ")
  (when (gaplay-buffer-p (current-buffer))
    (save-excursion
      (gaplay-render-message text 10 t))))
					  
;; **********  playlist *****************
(defun gaplay-set-local (symvalue-list)
  (mapc
   #'(lambda (symvalue)
       (unless (local-variable-p (car symvalue))
	 (set (make-local-variable (car symvalue)) (cdr symvalue))))
   symvalue-list))

(if gaplay-debug-mode (unintern 'gaplay-playlist-mode-map))
(define-minor-mode gaplay-playlist-mode
  "Minor mode for viewing gaplay playlist
  \\{gaplay-playlist-mode-map}" 
  nil " gaplay-playlist"
  :global nil
  :keymap '(("\C-ce" . (lambda () (interactive) (gaplay-playlist-mode -1)))
	    (" " . scroll-up) ("\C-?" . scroll-down)
	    (">" . end-of-buffer) ("<" . beginning-of-buffer)
	    ("q" . gaplay-quit-plylst) ("l" . gaplay-show-player)
	    ("d" . gaplay-del-plylst-entry)
	    ([return] . gaplay-plylst-select-current)
	    ("\r" . gaplay-plylst-select-current)
	    ("\n" . gaplay-plylst-select-current)
	    ("p" . gaplay-play-previous) ("n" . gaplay-play-next)
	    ("\M-d" . gaplay-clear-plylst)
	    ("\C-xu" . gaplay-undo-plylst)
	    ("o" . gaplay-load) ("a" . gaplay-add)
	    ("\C-co" . gaplay-load-m3u) ("\C-ca" . gaplay-add-m3u)
	    ("c" . gaplay-shoutcast)
	    ("+" . gaplay-up-gain) (";" . gaplay-up-gain)
	    ("-" . gaplay-down-gain) ("=" . gaplay-down-gain)
	    ("[" . gaplay-seek-backward) ("]" . gaplay-seek-forward)
	    ("\M-[" . gaplay-seek-bbackward) ("\M-]" . gaplay-seek-fforward)
	    ("L" . gaplay-toggle-loop) ("S" . gaplay-toggle-shuffle)
	    )
  (when (gaplay-buffer-p)
    (setq gaplay-playlist-mode nil)
    (error "Current buffer is player buffer"))
  (if gaplay-playlist-mode
      (progn
	;; (set-buffer-multibyte t) ;; ????
	(gaplay-set-local '((gaplay-player-buffer) (gaplay-play-marker)
			    (gaplay-marker-overlay)
			    (kill-buffer-query-functions gaplay-plylst-query-kill)
			    ))
	(when (null gaplay-play-marker)
	  (setq gaplay-play-marker (point-max-marker))
	  (set-marker-insertion-type gaplay-play-marker nil))
	(when (null gaplay-marker-overlay)
	  (setq gaplay-marker-overlay (make-overlay 1 1))
	  (overlay-put gaplay-marker-overlay 'face '(underline (:height 1.2)))
	  )))
  (setq buffer-read-only gaplay-playlist-mode)
  (if (and (markerp gaplay-play-marker)
	   (overlayp gaplay-marker-overlay))
      (gaplay-plylst-hilight-marker gaplay-playlist-mode))
  )

(defun gaplay-plylst-query-kill ()
  (if (and (bufferp gaplay-player-buffer)
	   (gaplay-top-plylst-pos)) ;; not-empty
      (y-or-n-p "Are you sure you want to kill the playlist? ") t))

(defun gaplay-plylst-buffer-p (&optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (and (local-variable-p 'gaplay-player-buffer)
	 (eq (current-buffer)
	     (with-current-buffer gaplay-player-buffer
	       gaplay-plylst-buffer)))))
    
;; Note: current-buffer must be gaplay-buffer-p or gaplay-plylst-buffer
(defun gaplay-get-plylst-buffer ()
  (cond ((gaplay-plylst-buffer-p) (current-buffer))
	((and (bufferp gaplay-plylst-buffer)
	   ;; buffer name is nil of deleted buffer
	   (buffer-name gaplay-plylst-buffer)) gaplay-plylst-buffer)
	(t
	 ;; create playlist buffer
	 (let ((plsbuf (generate-new-buffer "*gaplay-playlist*"))
	       (player-buffer (current-buffer)))
	   (setq gaplay-plylst-buffer
		 (with-current-buffer plsbuf
		   (gaplay-playlist-mode 1)
		   (setq truncate-lines t) ;; no wrap
		   (setq line-spacing 0.15)
		   (setq gaplay-player-buffer player-buffer)
		   (make-local-hook 'kill-buffer-hook) ;; no need since 21.1
		   (add-hook 'kill-buffer-hook
			     #'(lambda () 
				 (if (markerp gaplay-play-marker)
				     (set-marker gaplay-play-marker nil))
				 (if (overlayp gaplay-marker-overlay)
				     (delete-overlay gaplay-marker-overlay))
				 (if (and (bufferp gaplay-player-buffer)
					  (buffer-name gaplay-player-buffer))
				     (with-current-buffer gaplay-player-buffer
				       (setq gaplay-plylst-buffer nil)
				       )))
			     nil t)
		   plsbuf
		   ))
	   ))))

(defun gaplay-plylst-hilight-marker (flag)
  (let ((flag (and (marker-position gaplay-play-marker) flag)))
    (if flag
	(save-excursion
	  (let* ((s (progn (goto-char gaplay-play-marker)
			   (beginning-of-line) (point)))
		 (e (progn (end-of-line) (point))))
	    (move-overlay gaplay-marker-overlay s e)))
      (move-overlay gaplay-marker-overlay 1 1))))

(defun gaplay-plylst-move-marker (pnt &optional hilight)
  "Move gaplay-play-marker to PNT or (point)"
  (save-excursion
    (goto-char (or pnt (point)))
    (beginning-of-line)
    (set-marker gaplay-play-marker (point))
    (if hilight (gaplay-plylst-hilight-marker t))))

;; Return beginning-point of new entry
;; Note: current-buffer must be gaplay-buffer or gaplay-plylst-buffer
(defun gaplay-add-plylst-entry (path &rest options)
  (let ((move-marker (plist-get options :move-marker))
	(show-marker (plist-get options :show-marker)))
  (with-current-buffer (gaplay-get-plylst-buffer)
    (let ((buffer-read-only nil))
      (prog1
	  (save-excursion
	    (if (plist-get options :new) (gaplay-erase-plylst))
	    (goto-char (or (plist-get options :pos) (point-max)))
	    (if (> (current-column) 0) (newline))
	    (let ((mkpnt (point)))
	      (if move-marker (gaplay-plylst-move-marker mkpnt))
	      (insert (concat path "\n"))
	      (if move-marker (gaplay-plylst-hilight-marker t))
	      mkpnt))
	(if show-marker
	    (let ((win (get-buffer-window (current-buffer))))
	      (if win (progn (goto-char (point-max))
			     (gaplay-show-point)))))
	)
      ))))

(defun gaplay-line-match (rx)
  (save-excursion
    (let ((epos (progn (end-of-line) (point))))
      (beginning-of-line)
      (re-search-forward rx epos t))))

(defun gaplay-empty-line-p ()
  (gaplay-line-match "^[ \t\r\n\f]*$"))

(defun gaplay-plylst-pos/point (&optional pnt) 
  "Return playlist-buffer position near the point"
  (save-excursion
    (if pnt (goto-char pnt))
    (beginning-of-line)
    (while (and (not (eobp)) (gaplay-empty-line-p)) (forward-line))
    (if (not (gaplay-empty-line-p)) (point) nil)))

(defun gaplay-top-plylst-pos ()  (gaplay-plylst-pos/point (point-min)))

(defun gaplay-bottom-plylst-pos ()
  (save-excursion
    (goto-char (point-max)) (beginning-of-line)
    (while (and (not (bobp)) (gaplay-empty-line-p)) (forward-line -1))
    (if (not (gaplay-empty-line-p)) (point) nil)))

(defun gaplay-next-plylst-pos (&optional pnt)
  "Retrun next playlist buffer point of PNT or current play-marker
   If no playlist, return nil"
  (save-excursion
    (let ((mrkpnt (if pnt (gaplay-plylst-pos/point pnt)
		    (and (markerp gaplay-play-marker)
			 (marker-position gaplay-play-marker)))))
      (if mrkpnt
	  (let ((start-pos
		 (progn (goto-char mrkpnt) (beginning-of-line) (point))))
	    (forward-line)
	    (while (and (not (eobp)) (gaplay-empty-line-p)) (forward-line))
	    (if (not (gaplay-empty-line-p))
		(let ((s (progn (beginning-of-line) (point))))
		  (if (> s start-pos) s nil)))) nil))))

(defun gaplay-prev-plylst-pos (&optional pnt)
  "Retrun previous playlist buffer point of PNT or current play-marker
   If no playlist, return nil"
  (save-excursion
    (let ((mrkpnt (if pnt (gaplay-plylst-pos/point pnt)
		    (and (markerp gaplay-play-marker)
			 (marker-position gaplay-play-marker)))))
      (if mrkpnt
	  (let ((start-pos
		 (progn (goto-char mrkpnt) (beginning-of-line) (point))))
	    (forward-line -1)
	    (while (and (not (bobp)) (gaplay-empty-line-p)) (forward-line -1))
	    (if (not (gaplay-empty-line-p))
		(let ((s (progn (beginning-of-line) (point))))
		  (if (< s start-pos) s nil)))) nil))))

(defun gaplay-line-content (pos)
  "Get string of line, POS is point or marker"
  (save-excursion
    (progn (goto-char pos) (gaplay-chop (thing-at-point 'line)))))

;; return next-entry or nil
;; OPTIONS  :backward :move-marker :show-marker :loop
(defun gaplay-goto-next-plylst (&rest options)
  (let ((isback (plist-get options :backward)))
    (let ((pos
	   (if (plist-get options :shuffle)
	       (gaplay-next-shuffle-pos isback (plist-get options :loop))
	     (or (if isback (gaplay-prev-plylst-pos) (gaplay-next-plylst-pos))
		 (and (plist-get options :loop)
		      (if isback (gaplay-bottom-plylst-pos) (gaplay-top-plylst-pos)))))))
      (if pos 
	  (let ((entry (progn (goto-char pos)
			      (gaplay-chop (thing-at-point 'line)))))
	    (if (plist-get options :move-marker)
		(gaplay-plylst-move-marker (point) t))
	    (if (plist-get options :show-marker)
		(gaplay-show-point pos))
	    entry) nil))))

(defun gaplay-goto-prev-plylst(&rest options)
  (apply #'gaplay-goto-next-plylst `(:backward t . ,options)))

;; Note: current-buffer must be gaplay-buffer or gaplay-plylst-buffer
(defun gaplay-play-next (&optional backward)
  (interactive)
  (if (or (and (gaplay-buffer-p) (bufferp gaplay-plylst-buffer))
	  (and (gaplay-plylst-buffer-p) (bufferp gaplay-player-buffer)))
      (let ((entry
	     (with-current-buffer (gaplay-get-plylst-buffer)
	       (gaplay-goto-next-plylst :backward backward
					;; :loop (gaplay-loop-mode-p)
					:loop t
					:shuffle (gaplay-shuffle-mode-p)
					:move-marker t :show-marker t))))
	(if entry
	    (with-current-buffer 
		(if (gaplay-buffer-p) (current-buffer)
		  gaplay-player-buffer)
	      (gaplay-load-source `((:path . ,entry))))))))

(defun gaplay-play-previous ()
  (interactive)
  (gaplay-play-next t))

(defun gaplay-plylst-select-current ()
  "Select a song at the current point"
  (interactive)
  (if (and (gaplay-plylst-buffer-p) (bufferp gaplay-player-buffer))
      (let ((pos (gaplay-plylst-pos/point)))
	(if pos
	    (let ((entry (gaplay-line-content pos)))
	      (goto-char pos)
	      (gaplay-plylst-move-marker pos t)
	      (when (gaplay-shuffle-mode-p)
		(gaplay-clear-order-all)
		(gaplay-shuffle-message)
		(gaplay-set-order 1 (marker-position gaplay-play-marker)))
	      (with-current-buffer gaplay-player-buffer
		(gaplay-load-source `((:path . ,entry)))))))))

(defun gaplay-del-plylst-entry-1 (&optional pnt)
  (save-excursion
    (let ((pos (gaplay-plylst-pos/point (or pnt (point)))))
      (if pos
	  (let* ((buffer-read-only nil)
		 (prev (gaplay-prev-plylst-pos pos))
		 (pos-s (if prev
			    (progn (goto-char prev) (forward-line) (point))
			  (point-min)))
		 (pos-e (progn (goto-char pos) (forward-line) (point))))
	    (delete-region pos-s pos-e)
	    (point)) nil))))

;; Note: current-buffer must be gaplay-plylst-buffer
(defun gaplay-del-plylst-entry (count)
  (interactive "p")
  (if (gaplay-plylst-buffer-p)
      (let* ((count (or count 1)) (count0 count))
	(catch 'break
	  (while (> count 0) 
	    (if (null (gaplay-del-plylst-entry-1)) (throw 'break nil))
	    (setq count (1- count))))
	(if (and (< count count0) (markerp gaplay-play-marker))
	    (gaplay-plylst-hilight-marker t)))))

;; Note: current-buffer must be gaplay-plylst-buffer
(defun gaplay-erase-plylst (&optional flush-undo)
  (let ((buffer-read-only nil))
    (erase-buffer)
    (if flush-undo (progn (buffer-disable-undo) buffer-enable-undo))
    (set-marker gaplay-play-marker (point-max))
    (gaplay-plylst-hilight-marker nil)
    ))

;; current-buffer must be gaplay-buffer or gaplay-plylst-buffer
(defun gaplay-clear-plylst ()
  "Clear all entries from the playList"
  (interactive)
  (if (gaplay-ask-yesno "Do you want to clear all fields? ")
      (if (or (and (gaplay-buffer-p) (bufferp gaplay-plylst-buffer))
	      (gaplay-plylst-buffer-p))
	  (with-current-buffer (gaplay-get-plylst-buffer)
	    (gaplay-erase-plylst)))))

(defun gaplay-undo-plylst (&optional arg)
  (interactive "P")
  (if (and (gaplay-plylst-buffer-p) gaplay-playlist-mode)
      (unwind-protect
	  (let ((buffer-read-only nil))
	    (gaplay-playlist-mode -1)
	    (undo arg))
	(gaplay-playlist-mode 1))))

;; Add ENTRIES(list of path) to playlist.
;; ISPLAY:  nil -- not-play  t -- play the first entry 
;; ADD-MODE:
;;   t       -- add entries to last of a buffer.
;;   numeric -- add entries after specified point
;;   nil     -- clear gaplay-plylst-buffer, and add entries after that.
;; NOTE: current-buffer must be gaplay-buffer or gaplay-plylst-buffer
(defun gaplay-load-entries (entries isplay &optional add-mode)
  (if entries
      (with-current-buffer (gaplay-get-plylst-buffer)
	(if (null add-mode) (gaplay-erase-plylst))
	(let ((poslist (gaplay-add-plylst/list
			entries (if (numberp add-mode) add-mode nil))))
	  (if (car poslist)
	      (let* ((shuffle (and (cdr poslist) (gaplay-shuffle-mode-p)))
		     (mpos (if shuffle (nth (random (length poslist)) poslist)
			     (car poslist))))
		(let ((path (gaplay-line-content mpos)))
		  (gaplay-plylst-move-marker mpos t)
		  (when shuffle
		    (gaplay-clear-order-all) (gaplay-shuffle-message)
		    (gaplay-set-order 1 (marker-position gaplay-play-marker)))
		  (if isplay
		      (with-current-buffer gaplay-player-buffer
			(gaplay-load-source `((:path . ,path)))))))
	    )))))
	
;; Add ENTRIES(path-list) to playlist
;; Return point-list, each of those element is the beginning position of 
;; the added lines. 
;; if POSITION is nil: add entries to the last of a buffer. 
;; if POSITION is numeric: add entries after the specified point.
;; NOTE: current-buffer must be gaplay-plylst-buffer
(defun gaplay-add-plylst/list (entries &optional position)
  (let ((pos position))
    (mapcar #'(lambda (path)
		(let ((addpnt (gaplay-add-plylst-entry path :pos pos)))
		  (if pos
		      (setq pos (save-excursion (goto-char addpnt)
						(forward-line) (point))))
		  addpnt))
	    entries)))
      
;; Return entry list of DIRECTORY
(defun gaplay-read-dir-entries (directory)
  (let ((title-number #'(lambda (title)
			  (and (string-match "^[0-9]+" title)
			       (string-to-number
				(substring title 0 (match-end 0)))))))
    (sort 
     (gaplay-collect
      ;; collect  plain-file and has '("mp3" "mp4" ...) extentions
      #'(lambda (entry)
	  (and (file-readable-p entry) (file-regular-p entry)
	       (member (downcase (or (file-name-extension entry) ""))
		       gaplay-avfile-extensions))
	  ) (directory-files directory t nil t))
     ;; sort with title-number
     #'(lambda (a b)
	 ;; (string-to-number "7ffffff" 16) ;-> 134217727 (28bit-maxint)
	 (let ((afile (file-name-nondirectory a))
	       (bfile (file-name-nondirectory b)))
	   (let ((na (or (funcall title-number afile) 134217727))
		 (nb (or (funcall title-number bfile) 134217727)))
	     (cond ((< na nb) t)
		   ((< nb na) nil)
		   ((string< a b) t)
		   (t nil)))))
     )))

(defun gaplay-readline ()
  (if (eobp) nil
    (let ((e (progn (end-of-line) (point))))
      (let ((line (buffer-substring (progn (beginning-of-line) (point)) e)))
	(forward-line)
	line))))

(defun gaplay-read-m3u-entries (file &optional settled) 
  "Read m3u FILE and return entry list
FILE must be absolute path"
  (if (member file settled) nil
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((entries nil) (line (gaplay-readline)) (case-fold-search t))
	(while line
	  (if (not (or (string-match "^#" line) (string-match "^[ \t\r\n\f]*$" line)))
	      (let ((line (gaplay-chop line)))
		(if (gaplay-url-file-p line) ;; Delete `file://'
		    (setq line (replace-regexp-in-string "^file://" "" line)))
		(setq entries
		      (if (gaplay-url-p line) (cons line entries)
			(let ((path 
			       (expand-file-name line (file-name-directory file))))
			  (cond ((not (file-readable-p path)) entries)
				((file-directory-p path)
				 (cons (gaplay-read-dir-entries path) entries))
				((file-regular-p path)
				 (let ((ext (downcase (or (file-name-extension path) ""))))
				   (cond
				    ((string= ext "m3u")
				     (cons
				      (gaplay-read-m3u-entries path (cons file settled))
				      entries))
				    ((string= ext "pls")
				     (cons
				      (gaplay-read-pls-entries path (cons file settled))
				      entries))
				    (t (cons path entries)))))
				(t entries)))))))
	  (setq line (gaplay-readline)))
	;; flatten and cut nil
	(gaplay-collect #'(lambda (x) x) ;; 
			(gaplay-flatten (nreverse entries)))
	))))

(defun gaplay-read-pls-entries (file &optional settled) 
  "Read pls FILE and return entry list
FILE must be absolute path"
  (if (member file settled) nil
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((entries nil) (line (gaplay-readline)) (case-fold-search t))
	(while line
	  (if (string-match "^[ \t]*file\\([0-9]+\\)=" line)
	      (let ((fno (string-to-number (match-string 1 line)))
		    (fname (gaplay-chop (substring line (match-end 0)))))
		(if (gaplay-url-file-p fname) ;; Delete `file://'
		    (setq fname (replace-regexp-in-string "^file://" "" fname)))
		(setq entries
		      (if (gaplay-url-p fname) (cons (cons fno fname)  entries)
			(let ((path 
			       (expand-file-name fname (file-name-directory file))))
			  (cond ((not (file-readable-p path)) entries)
				((file-directory-p path)
				 (cons (cons fno (gaplay-read-dir-entries path))
				       entries))
				((file-regular-p path)
				 (let ((ext (downcase (or (file-name-extension path) ""))))
				   (cond ((string= ext "m3u")
					  (cons (cons fno (gaplay-read-m3u-entries
							   path (cons file settled)))
						entries))
					 ((string= ext "pls")
					  (cons (cons fno (gaplay-read-pls-entries
							   path (cons file settled)))
						entries))
					 (t (cons (cons fno path) entries)))))
				(t entries)))))))
	  (setq line (gaplay-readline)))
	;; sort by fno -> map cdr -> flatten -> filter not-nil
	(gaplay-collect
	 #'(lambda (x) x)
	 (gaplay-flatten
	  (mapcar #'cdr (sort entries #'(lambda (a b) (< (car a) (car b)))))))
	))))

;; ***************** shuffling playlist ***********************
(defun gaplay-delete-nth (nth lst)
  "Delete NTH LST entry and returns (deleted-entry deleted-list)"
  (let* ((top (cons nil lst))
	 (prev (nthcdr nth top))
	 (del (cadr prev)))
    (rplacd prev (cddr prev))
    (cons del (cdr top))))
	 
(defun gaplay-shuffle-list (lst)
  (let ((len (length lst)) (shuffled nil))
    (while (> len 0)
      (let ((dlpair (gaplay-delete-nth (random len) lst)))
	(setq shuffled (cons (car dlpair) shuffled))
	(setq lst (cdr dlpair))
	(setq len (1- len))))
    shuffled))

(defun gaplay-get-order (&optional pnt)
  (save-excursion
    (if pnt (goto-char pnt))
    (beginning-of-line)
    (get-text-property (point) 'gaplay-play-order)))
		  
(defun gaplay-set-order (order &optional pnt)
  (save-excursion
    (let ((buffer-read-only nil))
      (if pnt (goto-char pnt))
      (beginning-of-line)
      (add-text-properties (point) (1+ (point)) 
			   `(gaplay-play-order ,order
					       rear-nonsticky (gaplay-play-order))
			   ))))

(defun gaplay-clear-order (&optional pnt)
  (interactive)
  (save-excursion
    (if pnt (goto-char pnt))
    (let ((buffer-read-only nil)
	  (s (progn (beginning-of-line) (point)))
	  (e (progn (end-of-line) (point))))
      (remove-text-properties
       s e '(rear-nonsticky nil gaplay-play-order nil)))))

(defun gaplay-clear-order-all ()
  (let ((buffer-read-only nil))
    (remove-text-properties
     (point-min) (point-max) '(rear-nonsticky nil gaplay-play-order nil))))

;; Scan ordered sources, and set non-ordered sources in order.
;; Return (min-order max-order ordered-list)
(defun gaplay-scan-order ()
  (save-excursion
    (let ((min-order nil) (max-order nil) 
	  (ordered-list nil) (non-ordered-list))
      (goto-char (point-min))
      (catch 'break
	(while (not (eobp))
	  (let ((pnt (gaplay-plylst-pos/point)))
	    (if (null pnt) (throw 'break nil))
	    (let ((order (gaplay-get-order pnt)))
	      (if order
		  (progn
		    (setq ordered-list (cons (cons order pnt) ordered-list))
		    (if (or (null min-order) (< order min-order))
			(setq min-order order))
		    (if (or (null max-order) (> order max-order) )
			(setq max-order order)))
		(setq non-ordered-list (cons pnt non-ordered-list))))
	    (goto-char pnt) (forward-line)
	    ))
	)
      ;; set order to non-ordered
      (if non-ordered-list
	  (let ((n (if max-order (1+ max-order) 1)))
	    (if (null min-order) (setq min-order 1))
	    (mapc #'(lambda (pnt)
		      (gaplay-set-order n pnt)
		      (setq ordered-list (cons (cons n pnt) ordered-list))
		      (setq n (1+ n)))
		  (gaplay-shuffle-list non-ordered-list))
	    (setq max-order (1- n))))
      (list min-order max-order ordered-list))))
		  
;; called from gaplay-goto-next-plylst
(defun gaplay-next-shuffle-pos (isback isloop)
  "Return next/previous shuffled playlist position"
  (let ((mpos (if (markerp gaplay-play-marker) (marker-position gaplay-play-marker)
		(gaplay-top-plylst-pos)))
	(sort-ord #'(lambda (ordlst &optional descent)
		      (sort ordlst
			    #'(lambda (a b)
				(funcall (if descent '> '<) (car a) (car b)))))))
    (if mpos
	(let* ((c-ord (gaplay-get-order mpos))
	       (scan (gaplay-scan-order))
	       (min-ord (car scan)) (max-ord (cadr scan))
	       (ordered (caddr scan)))
	  ;; (gaplay-scan-log min-ord max-ord ordered) ;; debug
	  (let ((next (cond ((null c-ord)
			     (if (cdr ordered) (gaplay-shuffle-message))
			     (car (funcall sort-ord ordered)))
			    (isback
			     (if (<= c-ord min-ord)
				 (if isloop (car (funcall sort-ord ordered t)) nil)
			       (find-if #'(lambda (pr) (< (car pr) c-ord))
					(funcall sort-ord ordered t))))
			    (t
			     (if (>= c-ord max-ord)
				 (if isloop (car (funcall sort-ord ordered )) nil)
			       (find-if #'(lambda (pr) (> (car pr) c-ord))
					(funcall sort-ord ordered )))))))
	    (and next (gaplay-plylst-pos/point (cdr next)))))
      nil)))

;; current buffer must be  gaplay-plylst-buffer
(defun gaplay-shuffle-message ()
  (let ((top (gaplay-top-plylst-pos))
	(bottom (gaplay-bottom-plylst-pos)))
    (if (and top bottom (not (= top bottom)))
	(message "Shuffle the playlist"))))

(defun gaplay-scan-log (min-order max-order ordered-list) ;; for debug
  (mylog "min=%s max=%s" min-order max-order)
  (mapc
   #'(lambda (opair)
       (mylog "[%3d] %s" (car opair) (gaplay-line-content (cdr opair))))
   ordered-list))

(if gaplay-debug-mode
    (defun gaplay-view-order () ;; for debug
      (interactive)
      (with-current-buffer (gaplay-get-plylst-buffer)
	(mylog "Current order:%s"
	       (and (markerp gaplay-play-marker) (marker-position gaplay-play-marker)
		    (gaplay-get-order gaplay-play-marker)))
	(save-excursion
	  (goto-char (point-min))
	  (let ((pos (gaplay-plylst-pos/point (point-min))))
	    (while (and (not (eobp)) pos)
	      (goto-char pos)
	      (mylog "%s:%s" (gaplay-get-order) (gaplay-line-content (point)))
	      (forward-line)
	      (setq pos (gaplay-plylst-pos/point)))
	    ))
	)))

(defun gaplay-quit-plylst ()
  (interactive)
  (when (and (gaplay-plylst-buffer-p (current-buffer))
	     (bufferp gaplay-player-buffer))
    (let ((wplayer (get-buffer-window gaplay-player-buffer)))
      (if wplayer
	  (progn (delete-windows-on (current-buffer) t)
		 (select-window wplayer))
	;; (set-window-buffer (selected-window) gaplay-player-buffer)
	(switch-to-buffer gaplay-player-buffer)))))

(defun gaplay-show-player ()
  "Toggle show/hide gaplay player buffer"
  (interactive)
  (when (and (gaplay-plylst-buffer-p (current-buffer))
	     (bufferp gaplay-player-buffer))
    (if (get-buffer-window gaplay-player-buffer)
	(delete-windows-on gaplay-player-buffer t)
      (display-buffer gaplay-player-buffer))))
    
;; ******** keybindings help *******************************************
;; e.g. (insert (gaplay-where-is 'gaplay-seek-forward nil '(underline)))
(defun gaplay-where-is (fsymbol &optional kmap face)
  (mapconcat #'(lambda (kdef)
                 (let ((s (key-description kdef)))
                   (if face (put-text-property 0 (length s) 'face face s))
                   s))  (where-is-internal fsymbol kmap) ", "))

(defun gaplay-render-keybind ()
  (gaplay-anchor:write (gaplay-find-anchor 'keybind-title)
		       "Key Bindings")
  (let ((face '(bold-italic underline )) (C-u "C-u "))
    (put-text-property 0 (length C-u) 'face face C-u)
    (gaplay-anchor:write
     (gaplay-find-anchor 'keybind)
     (mapconcat
      #'(lambda (pair) 
	  (let ((kbind (and (cdr pair)
			    (gaplay-where-is (cdr pair) nil face))))
	    (if kbind (format (car pair) kbind)
	      (car pair))))
      `(("    Hide/Show this help: %s" . gaplay-show-keybind)
	("    Quit: %s\n" . gaplay-quit)
	("    Open File or Folder: %s" . gaplay-load)
	(,(concat "    Open URL: " C-u "%s\n") . gaplay-load)
	("    Add File or Folder to playlist: %s" . gaplay-add)
	(,(concat "    Add URL to playlist: " C-u "%s\n") . gaplay-add)
	("\n")
	("    Play/Pause: %s" . gaplay-toggle-pause)
	("    Stop: %s" . gaplay-stop)
	("    Replay song: %s\n" . gaplay-replay)
	("    Next: %s" . gaplay-play-next)
	("    Previous: %s\n" . gaplay-play-previous)
	("    Increase Volume: %s" . gaplay-up-gain)
	("    Decrease Volume: %s" . gaplay-down-gain)
	("    Mute: %s\n" . gaplay-mute)
	("    Step Forward: %s" . gaplay-seek-forward)
	("    Step Backward: %s\n" . gaplay-seek-backward)
	("    Jump to Time: %s\n" . gaplay-jump)
	("\n")
	("    Turn repeat mode On/Off: %s" . gaplay-toggle-loop)
	("    Turn shuffle mode On/Off: %s\n" . gaplay-toggle-shuffle)
	("\n")
	("    Hide/Show playlist window: %s\n" . gaplay-show-plylst)
	("    Shrink window: %s\n" . gaplay-shrink-player)
	)
      "")
     )))

(defun gaplay-show-keybind (&optional not-toggle)
  "Show/Hide key bindings help."
  (interactive)
  (if (gaplay-buffer-p)
      (progn
	(if (not not-toggle)
	    (setq gaplay-keybindings-visible (not gaplay-keybindings-visible)))
	(mapc
	 #'(lambda (anc)
	     (gaplay-anchor:overlay-put (gaplay-find-anchor anc) 'invisible
					(not gaplay-keybindings-visible)))
	 '(keybind-title keybind))
	(when (interactive-p)
	  (goto-char
	   (gaplay-anchor:start
	    (gaplay-find-anchor 
	     (if gaplay-keybindings-visible 'keybind-title 'time))))
	  (beginning-of-line)
	  (gaplay-show-point)))))

(defun gaplay-plsfile-p (file)
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((line (gaplay-readline)) (case-fold-search t))
      (while (and line (or (string-match "^;" line)
			   (string-match "^[ \t\r\n\f]*$" line)))
	(setq line (gaplay-readline)))
      (and line (string= "[playlist]" (downcase (gaplay-trim line)))))))

(provide 'gaplay)

;;; gaplay.el ends here
