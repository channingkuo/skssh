;;; skssh-sftp.el --- Dual-pane SFTP file manager  -*- lexical-binding: t; -*-
;;; Commentary:
;; Split-window dired-based SFTP with drag-drop path detection.
;;; Code:

(require 'dired)
(require 'transient)
(require 'skssh-core)

;;; Path detection

(defconst skssh-sftp--path-regexp
  (rx bol
      (or (or "/" "~/")
          (seq (char "A-Za-z") ":" (or "/" "\\")))
      (* nonl)
      eol)
  "Regexp matching absolute file paths (Unix, macOS, Windows).")

(defun skssh-sftp--path-p (str)
  "Return non-nil if STR matches a file path and the file exists."
  (and (string-match-p skssh-sftp--path-regexp str)
       (file-exists-p (expand-file-name str))))

;;; Transfer direction

(defun skssh-sftp--transfer-direction (local-window remote-window)
  "Return transfer direction symbol based on selected window.
Returns \\='upload if REMOTE-WINDOW is selected (local → remote).
Returns \\='download if LOCAL-WINDOW is selected (remote → local).
Returns nil if neither window is selected."
  (cond
   ((eq (selected-window) remote-window) 'upload)
   ((eq (selected-window) local-window)  'download)
   (t nil)))

;;; File transfer

(defun skssh-sftp--transfer (src-path dest-dir)
  "Copy SRC-PATH into DEST-DIR atomically using a temp file.
SRC-PATH or DEST-DIR may be TRAMP paths."
  (condition-case err
      (let* ((fname     (file-name-nondirectory src-path))
             (dest-path (expand-file-name fname dest-dir))
             (tmp-path  (expand-file-name
                         (concat ".skssh-tmp-" fname)
                         dest-dir)))
        (copy-file src-path tmp-path t)
        (rename-file tmp-path dest-path t)
        (message "skssh-sftp: transferred %s → %s" fname dest-dir))
    (error
     (message "skssh-sftp: transfer failed: %s" (error-message-string err)))))

;;; Dual-pane layout

(defvar-local skssh-sftp--local-window  nil "The local dired window in skssh-sftp session.")
(defvar-local skssh-sftp--remote-window nil "The remote TRAMP dired window in skssh-sftp session.")
(defvar-local skssh-sftp--host nil "The connected host plist for this skssh-sftp buffer.")

(defvar skssh-sftp-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map dired-mode-map)
    (define-key map (kbd "C")   #'skssh-sftp-copy-to-other)
    (define-key map (kbd "TAB") #'skssh-sftp-switch-pane)
    (define-key map (kbd "g")   #'skssh-sftp-refresh)
    (define-key map (kbd "h")   #'skssh-sftp-help)
    (define-key map (kbd "q")   #'skssh-sftp-quit)
    (define-key map [remap dired-find-file]    #'skssh-sftp-find-file)
    (define-key map [remap dired-up-directory] #'skssh-sftp-up-directory)
    map)
  "Keymap for `skssh-sftp-mode'.")

(define-minor-mode skssh-sftp-mode
  "Minor mode active in skssh SFTP dual-pane dired buffers."
  :lighter " skssh-sftp"
  :keymap skssh-sftp-mode-map
  (if skssh-sftp-mode
      (add-hook 'after-change-functions #'skssh-sftp--detect-dropped-path nil t)
    (remove-hook 'after-change-functions #'skssh-sftp--detect-dropped-path t)))

(defun skssh-sftp-open (host)
  "Open SFTP dual-pane for HOST plist.
Left pane = local home dir, right pane = remote home dir."
  (delete-other-windows)
  (let* ((local-buf  (dired-noselect "~"))
         (remote-buf (skssh--with-tramp-auth
                       (dired-noselect (skssh--tramp-path host))))
         (lwin (selected-window))
         (rwin (split-window-right)))
    (set-window-buffer lwin local-buf)
    (with-current-buffer local-buf
      (skssh-sftp-mode 1)
      (setq skssh-sftp--local-window  lwin
            skssh-sftp--remote-window rwin
            skssh-sftp--host          host)
      (rename-buffer (format "*skssh-local:%s*" (plist-get host :label)) t))
    (set-window-buffer rwin remote-buf)
    (with-current-buffer remote-buf
      (skssh-sftp-mode 1)
      (setq skssh-sftp--local-window  lwin
            skssh-sftp--remote-window rwin
            skssh-sftp--host          host)
      (rename-buffer (format "*skssh-remote:%s*" (plist-get host :label)) t))
    (select-window lwin)))

;;; Pane operations

(defun skssh-sftp--other-dir ()
  "Return the directory shown in the opposite pane."
  (let* ((other-win (if (eq (selected-window) skssh-sftp--local-window)
                        skssh-sftp--remote-window
                      skssh-sftp--local-window))
         (other-buf (window-buffer other-win)))
    (with-current-buffer other-buf
      (dired-current-directory))))

(defun skssh-sftp-copy-to-other ()
  "Copy marked files (or file at point) to the opposite pane."
  (interactive)
  (let ((files    (dired-get-marked-files nil nil nil t))
        (dest-dir (skssh-sftp--other-dir)))
    (dolist (f files)
      (skssh-sftp--transfer f dest-dir))
    (skssh-sftp-refresh)))

(defun skssh-sftp-switch-pane ()
  "Switch focus to the opposite pane."
  (interactive)
  (let ((other (if (eq (selected-window) skssh-sftp--local-window)
                   skssh-sftp--remote-window
                 skssh-sftp--local-window)))
    (select-window other)))

(defun skssh-sftp--visit-dir (dir)
  "Replace the current pane buffer with DIR, keeping `skssh-sftp-mode' active.
DIR may be a local path or a TRAMP path."
  (let ((host     skssh-sftp--host)
        (lwin     skssh-sftp--local-window)
        (rwin     skssh-sftp--remote-window)
        (is-local (eq (selected-window) skssh-sftp--local-window)))
    (set-buffer-modified-p nil)
    (find-alternate-file dir)
    (skssh-sftp-mode 1)
    (setq skssh-sftp--local-window  lwin
          skssh-sftp--remote-window rwin
          skssh-sftp--host          host)
    (when (and host (plist-get host :label))
      (rename-buffer
       (format (if is-local "*skssh-local:%s*" "*skssh-remote:%s*")
               (plist-get host :label))
       t))))

(defun skssh-sftp-find-file ()
  "Visit the file or directory at point.
Directories replace the current pane in place, keeping `skssh-sftp-mode'
active.  Regular files are opened as in ordinary dired."
  (interactive)
  (let ((target (dired-get-file-for-visit)))
    (if (file-directory-p target)
        (skssh-sftp--visit-dir (file-name-as-directory target))
      (dired-find-file))))

(defun skssh-sftp-up-directory ()
  "Go up one directory in the current pane, keeping `skssh-sftp-mode' active."
  (interactive)
  (skssh-sftp--visit-dir
   (file-name-directory (directory-file-name default-directory))))

(defun skssh-sftp-refresh ()
  "Revert both local and remote dired buffers."
  (interactive)
  (when (window-live-p skssh-sftp--local-window)
    (with-current-buffer (window-buffer skssh-sftp--local-window)
      (revert-buffer)))
  (when (window-live-p skssh-sftp--remote-window)
    (with-current-buffer (window-buffer skssh-sftp--remote-window)
      (revert-buffer))))

(defun skssh-sftp-quit ()
  "Close SFTP dual-pane and return to skssh host list."
  (interactive)
  (let ((lbuf (window-buffer skssh-sftp--local-window))
        (rbuf (window-buffer skssh-sftp--remote-window)))
    (delete-other-windows)
    (kill-buffer lbuf)
    (when (buffer-live-p rbuf) (kill-buffer rbuf))
    (when (get-buffer "*skssh*")
      (switch-to-buffer "*skssh*"))))

;;; Drag-drop path detection

(defun skssh-sftp--detect-dropped-path (beg end _len)
  "Detect file paths inserted into the dired buffer (terminal drag-drop).
BEG and END delimit the changed region."
  (let ((inserted (string-trim
                   (buffer-substring-no-properties beg end))))
    (when (skssh-sftp--path-p inserted)
      (let ((path (expand-file-name inserted))
            (dir  (skssh-sftp--transfer-direction
                   skssh-sftp--local-window
                   skssh-sftp--remote-window)))
        (let ((inhibit-modification-hooks t))
          (delete-region beg end))
        (when dir
          (let ((dest (if (eq dir 'upload)
                          (with-current-buffer
                              (window-buffer skssh-sftp--remote-window)
                            (dired-current-directory))
                        (with-current-buffer
                            (window-buffer skssh-sftp--local-window)
                          (dired-current-directory)))))
            (skssh-sftp--transfer path dest)
            (skssh-sftp-refresh)))))))

;;; Help / key reference

(transient-define-prefix skssh-sftp-help ()
  "Show key bindings for the dual-pane SFTP session."
  [:description
   (lambda ()
     (if (and skssh-sftp--host (plist-get skssh-sftp--host :label))
         (format "skssh-sftp keys — %s"
                 (plist-get skssh-sftp--host :label))
       "skssh-sftp keys"))
   ["Transfer"
    ("C" "Copy marked to other pane" skssh-sftp-copy-to-other)]
   ["Navigate"
    ("TAB" "Switch pane"       skssh-sftp-switch-pane)
    ("RET" "Enter directory"   skssh-sftp-find-file)
    ("^"   "Up one directory"  skssh-sftp-up-directory)
    ("g"   "Refresh panes"     skssh-sftp-refresh)]
   ["Session"
    ("h" "Show this help" skssh-sftp-help)
    ("q" "Quit SFTP"      skssh-sftp-quit)]])

(provide 'skssh-sftp)
;;; skssh-sftp.el ends here
