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
REMOTE-PATH defaults to \"/\"."
  (let ((user  (plist-get host :user))
        (hname (plist-get host :host))
        (port  (plist-get host :port))
        (rpath (or remote-path "/")))
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

(defun skssh--connect-shell (host)
  "Open a TRAMP shell buffer for HOST plist. Returns the buffer."
  (skssh--with-tramp-auth
    (let* ((tramp-path (skssh--tramp-path host))
           (default-directory tramp-path)
           (buf (shell (format "*skssh-shell:%s*" (plist-get host :label)))))
      (skssh--session-register (plist-get host :id) buf)
      buf)))

(defun skssh--connect-dired (host)
  "Open a TRAMP dired buffer for HOST plist. Returns the buffer."
  (skssh--with-tramp-auth
    (let* ((tramp-path (skssh--tramp-path host))
           (buf (dired-noselect tramp-path)))
      (skssh--session-register (plist-get host :id) buf)
      (switch-to-buffer buf)
      buf)))

(provide 'skssh-core)
;;; skssh-core.el ends here
