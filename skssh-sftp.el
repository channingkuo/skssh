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
    (define-key map (kbd "H")   #'skssh-sftp-toggle-detail-columns)
    (define-key map (kbd "q")   #'skssh-sftp-quit)
    (define-key map [remap dired-find-file]    #'skssh-sftp-find-file)
    (define-key map [remap dired-up-directory] #'skssh-sftp-up-directory)
    ;; Drag-drop / paste interception.  Dired buffers are read-only, so
    ;; we can't rely on `after-change-functions' firing when the terminal
    ;; pastes a dropped path -- the insertion itself is rejected first
    ;; with "Buffer is read-only".  Instead we catch the paste events
    ;; and dispatch the transfer without touching buffer contents.
    (define-key map [xterm-paste]           #'skssh-sftp-handle-xterm-paste)
    (define-key map [remap yank]            #'skssh-sftp-yank)
    (define-key map [remap yank-from-kill-ring] #'skssh-sftp-yank)
    map)
  "Keymap for `skssh-sftp-mode'.")

(defcustom skssh-sftp-hide-detail-columns t
  "If non-nil, hide links/user/group columns in SFTP dired panes.
This controls the default state when a pane is first opened.
Toggle interactively with \\[skssh-sftp-toggle-detail-columns]."
  :type 'boolean
  :group 'skssh)

(defvar-local skssh-sftp--columns-hidden nil
  "Buffer-local flag: non-nil when detail columns are currently hidden.")

(define-minor-mode skssh-sftp-mode
  "Minor mode active in skssh SFTP dual-pane dired buffers."
  :lighter " skssh-sftp"
  :keymap skssh-sftp-mode-map
  (if skssh-sftp-mode
      (progn
        (add-hook 'dired-after-readin-hook #'skssh-sftp--apply-column-visibility nil t)
        ;; Only seed the default when we haven't been here before.
        ;; `skssh-sftp--visit-dir' pre-sets this to preserve the user's
        ;; toggle across directory navigation.
        (unless (local-variable-p 'skssh-sftp--columns-hidden)
          (setq skssh-sftp--columns-hidden skssh-sftp-hide-detail-columns))
        (skssh-sftp--apply-column-visibility))
    (remove-hook 'dired-after-readin-hook #'skssh-sftp--apply-column-visibility t)
    (remove-overlays (point-min) (point-max) 'skssh-sftp-hidden t)))

;;; Column hiding (hide links/user/group in dired listing)

(defconst skssh-sftp--detail-columns-regexp
  (rx bol
      (* (any " \t"))
      ;; File type + 9 permission bits — always 10 chars, stays visible.
      (any "-dlcbspDLP")
      (= 9 (any "-rwxstSTl"))
      ;; Group 1 = everything from (optional) ACL/xattr marker through
      ;; the whitespace that precedes the size column.  Hiding this
      ;; whole span keeps the visible prefix of every row at a fixed
      ;; width of exactly 10 chars, which is what makes the remaining
      ;; columns line up once we pad the size column back via `display'.
      (group
       (? (any "@+."))
       (+ (any " \t"))
       (+ digit)             (+ (any " \t"))
       (+ (not (any " \t"))) (+ (any " \t"))
       (+ (not (any " \t"))) (+ (any " \t")))
      ;; Group 2 = the size token (e.g. "1568" or "1.5K").
      (group (+ (not (any " \t")))))
  "Regexp matching a dired -l line.
Group 1 covers marker/links/user/group plus the separating
whitespace; it is replaced by a computed `display' string so that
the size column becomes right-aligned.  Group 2 is the size token,
used only to measure its width.")

(defun skssh-sftp--hide-detail-columns ()
  "Hide links/user/group columns in the current dired buffer.
Sizes are realigned so the size column is right-aligned, which
keeps the date and filename columns lined up across rows.  The
underlying buffer text is preserved, so dired operations keep
working unchanged."
  (remove-overlays (point-min) (point-max) 'skssh-sftp-hidden t)
  (let ((rows nil)
        (max-size 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (beginning-of-line)
        (when (looking-at skssh-sftp--detail-columns-regexp)
          (let ((size-w (- (match-end 2) (match-beginning 2))))
            (setq max-size (max max-size size-w))
            (push (list (match-beginning 1) (match-end 1) size-w) rows)))
        (forward-line 1)))
    (dolist (row rows)
      (let* ((beg (nth 0 row))
             (end (nth 1 row))
             (sw  (nth 2 row))
             ;; One separator space + padding to right-align the size.
             (pad (make-string (1+ (- max-size sw)) ?\s))
             (ov  (make-overlay beg end)))
        (overlay-put ov 'display pad)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'skssh-sftp-hidden t)))))

(defun skssh-sftp--apply-column-visibility ()
  "Apply or clear column hiding per `skssh-sftp--columns-hidden'."
  (if skssh-sftp--columns-hidden
      (skssh-sftp--hide-detail-columns)
    (remove-overlays (point-min) (point-max) 'skssh-sftp-hidden t)))

(defun skssh-sftp-toggle-detail-columns ()
  "Toggle visibility of links/user/group columns in both SFTP panes."
  (interactive)
  (let ((new-state (not skssh-sftp--columns-hidden)))
    (dolist (win (list skssh-sftp--local-window skssh-sftp--remote-window))
      (when (window-live-p win)
        (with-current-buffer (window-buffer win)
          (setq skssh-sftp--columns-hidden new-state)
          (skssh-sftp--apply-column-visibility))))
    (message "skssh-sftp: detail columns %s"
             (if new-state "hidden" "shown"))))

(defun skssh-sftp-open (host)
  "Open SFTP dual-pane for HOST plist.
Left pane = local home dir, right pane = remote home dir."
  (delete-other-windows)
  (let* ((local-buf  (dired-noselect "~"))
         (remote-buf (skssh--with-tramp-auth
                       (dired-noselect (skssh--tramp-path host))))
         (lwin (selected-window))
         (rwin (split-window-right)))
    (skssh--session-register (plist-get host :id) remote-buf)
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
        (hidden   skssh-sftp--columns-hidden)
        (is-local (eq (selected-window) skssh-sftp--local-window)))
    (set-buffer-modified-p nil)
    (find-alternate-file dir)
    ;; Seed the buffer-local toggle state BEFORE enabling the mode so
    ;; `skssh-sftp-mode' activation picks up the user's current choice
    ;; instead of reverting to `skssh-sftp-hide-detail-columns'.
    (setq-local skssh-sftp--columns-hidden hidden)
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
;;
;; Dired buffers are read-only, so trying to insert a dropped path into
;; one fails with "Buffer is read-only" before any `after-change-functions'
;; hook gets a chance to run.  We therefore intercept the paste events
;; themselves -- `xterm-paste' (terminal bracketed paste, which is how
;; most terminal emulators deliver drag-drop) and `yank' -- and dispatch
;; the transfer directly, without touching buffer contents.

(defun skssh-sftp--dest-dir-for-direction (dir)
  "Return the destination directory for transfer DIR (\\='upload or \\='download)."
  (cond
   ((eq dir 'upload)
    (with-current-buffer (window-buffer skssh-sftp--remote-window)
      (dired-current-directory)))
   ((eq dir 'download)
    (with-current-buffer (window-buffer skssh-sftp--local-window)
      (dired-current-directory)))))

(defun skssh-sftp--dispatch-dropped-path (path)
  "Transfer PATH to the directory shown in the opposite pane.
The selected window decides the direction: dropping into the remote
pane uploads, dropping into the local pane downloads."
  (let ((dir (skssh-sftp--transfer-direction
              skssh-sftp--local-window
              skssh-sftp--remote-window)))
    (if (not dir)
        (message "skssh-sftp: not inside an SFTP pane, ignoring drop")
      (let ((dest (skssh-sftp--dest-dir-for-direction dir)))
        (skssh-sftp--transfer (expand-file-name path) dest)
        (skssh-sftp-refresh)))))

(defun skssh-sftp--maybe-transfer-paste (text)
  "Treat TEXT as a possible dropped file path and transfer if valid.
Strips surrounding whitespace/newlines first (terminals often append a
trailing newline to bracketed-paste payloads)."
  (let ((trimmed (string-trim (or text ""))))
    (cond
     ((string-empty-p trimmed)
      (message "skssh-sftp: empty paste ignored"))
     ((skssh-sftp--path-p trimmed)
      (skssh-sftp--dispatch-dropped-path trimmed))
     (t
      (message "skssh-sftp: paste is not an existing file path: %s"
               trimmed)))))

(defun skssh-sftp-handle-xterm-paste (event)
  "Handle terminal bracketed-paste EVENT inside an SFTP pane.
Detects dropped file paths and transfers them to the opposite pane,
avoiding the \"Buffer is read-only\" error you would otherwise get
trying to paste text into a dired buffer."
  (interactive "e")
  (skssh-sftp--maybe-transfer-paste (nth 1 event)))

(defun skssh-sftp-yank ()
  "Yank replacement for SFTP panes.
If the top of the kill-ring is an existing file path, transfer it to
the opposite pane.  Plain `yank' would fail here anyway because dired
buffers are read-only; this turns the failing keystroke into a useful
drag-drop-style transfer instead."
  (interactive)
  (skssh-sftp--maybe-transfer-paste (current-kill 0 t)))

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
    ("C"   "Copy marked to other pane" skssh-sftp-copy-to-other)
    ("C-y" "Paste/drop path to this pane" skssh-sftp-yank)]
   ["Navigate"
    ("TAB" "Switch pane"       skssh-sftp-switch-pane)
    ("RET" "Enter directory"   skssh-sftp-find-file)
    ("^"   "Up one directory"  skssh-sftp-up-directory)
    ("g"   "Refresh panes"     skssh-sftp-refresh)]
   ["View"
    ("H" "Toggle links/user/group columns"
     skssh-sftp-toggle-detail-columns)]
   ["Session"
    ("h" "Show this help" skssh-sftp-help)
    ("q" "Quit SFTP"      skssh-sftp-quit)]])

(provide 'skssh-sftp)
;;; skssh-sftp.el ends here
