;;; skssh-core.el --- TRAMP connection management  -*- lexical-binding: t; -*-
;;; Commentary:
;; Builds TRAMP paths and tracks active SSH sessions.
;;; Code:

(require 'tramp)
(require 'skssh-config)

(defvar skssh--active-sessions (make-hash-table :test 'equal)
  "Active TRAMP sessions. Key = host :id string, value = buffer.")

(defmacro skssh--with-tramp-auth (&rest body)
  "Run BODY with TRAMP auth-source lookup forced on.
TRAMP only consults auth-source when
`tramp-cache-read-persistent-data' is non-nil (see tramp.el
`tramp-process-actions' and `tramp-read-passwd').  Scope the
override to skssh's own connection calls so the user's global
setting is preserved."
  (declare (indent 0) (debug t))
  `(let ((tramp-cache-read-persistent-data t))
     ,@body))

(defun skssh--tramp-path (host &optional remote-path)
  "Build TRAMP /ssh: path string for HOST plist.
REMOTE-PATH defaults to \"~/\" so that shell, dired, and SFTP land in
the login user's home directory on the remote host."
  (let ((user  (plist-get host :user))
        (hname (plist-get host :host))
        (port  (plist-get host :port))
        (rpath (or remote-path "~/")))
    (if (and port (/= port 22))
        (format "/ssh:%s@%s#%d:%s" user hname port rpath)
      (format "/ssh:%s@%s:%s" user hname rpath))))

(defun skssh--session-register (host-id buffer)
  "Register BUFFER as the active session for HOST-ID."
  (puthash host-id buffer skssh--active-sessions))

(defun skssh--session-remove (host-id)
  "Remove session entry for HOST-ID."
  (remhash host-id skssh--active-sessions))

(defun skssh--session-active-p (host-id)
  "Return non-nil if HOST-ID has a live active session buffer."
  (let ((buf (gethash host-id skssh--active-sessions)))
    (and buf (buffer-live-p buf))))

(defvar skssh-shell-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c q") #'skssh-shell-quit)
    map)
  "Keymap for `skssh-shell-mode'.")

(define-minor-mode skssh-shell-mode
  "Minor mode active in skssh-managed shell buffers.
Provides `C-c q' to kill the shell and return to the host list."
  :lighter " skssh-shell"
  :keymap skssh-shell-mode-map)

(defun skssh-shell-quit ()
  "Kill the current skssh shell buffer and return to the host list."
  (interactive)
  (let ((buf (current-buffer)))
    (maphash (lambda (id b)
               (when (eq b buf) (remhash id skssh--active-sessions)))
             skssh--active-sessions)
    (when-let ((proc (get-buffer-process buf)))
      (set-process-query-on-exit-flag proc nil))
    (kill-buffer buf))
  (when (get-buffer "*skssh*")
    (switch-to-buffer "*skssh*")))

(defun skssh--connect-shell (host)
  "Open a TRAMP shell buffer for HOST plist. Returns the buffer."
  (skssh--with-tramp-auth
    (let* ((tramp-path (skssh--tramp-path host))
           (default-directory tramp-path)
           (buf (shell (format "*skssh-shell:%s*" (plist-get host :label)))))
      (skssh--session-register (plist-get host :id) buf)
      (with-current-buffer buf
        (skssh-shell-mode 1)
        (add-hook 'kill-buffer-hook
                  (let ((id (plist-get host :id)))
                    (lambda () (skssh--session-remove id)))
                  nil t))
      buf)))

(defvar skssh-dired-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c q") #'skssh-dired-quit)
    (define-key map (kbd "q")     #'skssh-dired-quit)
    map)
  "Keymap for `skssh-dired-mode'.
`q' is rebound from the default `quit-window' (which leaves the buffer
alive) to `skssh-dired-quit', so the dired buffer and its TRAMP session
are fully cleaned up on exit.")

(define-minor-mode skssh-dired-mode
  "Minor mode active in skssh-managed dired buffers.
Provides `C-c q' to kill the dired buffer and return to the host list."
  :lighter " skssh-dired"
  :keymap skssh-dired-mode-map)

(defun skssh-dired-quit ()
  "Kill the current skssh dired buffer and return to the host list.
Runs `quit-window' with KILL=t so both the window and the buffer go."
  (interactive)
  (let ((buf (current-buffer)))
    (maphash (lambda (id b)
               (when (eq b buf) (remhash id skssh--active-sessions)))
             skssh--active-sessions)
    (quit-window t))
  (when (get-buffer "*skssh*")
    (switch-to-buffer "*skssh*")))

(defun skssh--connect-dired (host)
  "Open a TRAMP dired buffer for HOST plist. Returns the buffer."
  (skssh--with-tramp-auth
    (let* ((tramp-path (skssh--tramp-path host))
           (buf (dired-noselect tramp-path)))
      (skssh--session-register (plist-get host :id) buf)
      (with-current-buffer buf
        (skssh-dired-mode 1)
        (add-hook 'kill-buffer-hook
                  (let ((id (plist-get host :id)))
                    (lambda () (skssh--session-remove id)))
                  nil t))
      (switch-to-buffer buf)
      buf)))

(provide 'skssh-core)
;;; skssh-core.el ends here
