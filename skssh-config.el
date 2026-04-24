;;; skssh-config.el --- SSH host config storage  -*- lexical-binding: t; -*-
;;; Commentary:
;; Reads and writes skssh host list (hosts.el).
;; Also parses ~/.ssh/config for one-time import.
;;; Code:

(require 'cl-lib)

(defgroup skssh nil
  "SSH connection manager."
  :group 'tools
  :prefix "skssh-")

(defcustom skssh-config-file
  (expand-file-name "skssh/hosts.el" user-emacs-directory)
  "Path to skssh hosts configuration file."
  :type 'file
  :group 'skssh)

(defun skssh--generate-id ()
  "Generate a pseudo-UUID string."
  (format "%08x-%04x-%04x-%04x-%012x"
          (random #xFFFFFFFF)
          (random #xFFFF)
          (random #xFFFF)
          (random #xFFFF)
          (random #xFFFFFFFFFFFF)))

(defun skssh--load-hosts ()
  "Load hosts from `skssh-config-file'.
Returns list of host plists, or nil if file missing or corrupt."
  (if (file-exists-p skssh-config-file)
      (with-temp-buffer
        (insert-file-contents skssh-config-file)
        (condition-case err
            (read (current-buffer))
          (error
           (message "skssh: failed to parse %s: %s" skssh-config-file err)
           nil)))
    nil))

(defun skssh--save-hosts (hosts)
  "Save HOSTS plist list to `skssh-config-file'."
  (let ((dir (file-name-directory skssh-config-file)))
    (unless (file-exists-p dir)
      (make-directory dir t))
    (with-temp-file skssh-config-file
      (let ((print-length nil)
            (print-level nil))
        (pp hosts (current-buffer))))))

(defun skssh--get-host (id hosts)
  "Return host plist with :id equal to ID from HOSTS, or nil."
  (cl-find id hosts :test #'equal
           :key (lambda (h) (plist-get h :id))))

(defun skssh--add-host (host hosts)
  "Add HOST plist to HOSTS list.
Assigns a new :id if HOST lacks one. Returns new list."
  (let ((h (if (plist-get host :id)
               host
             (append (list :id (skssh--generate-id)) host))))
    (append hosts (list h))))

(defun skssh--update-host (id updated hosts)
  "Replace host with :id = ID in HOSTS with UPDATED plist.
Returns new list."
  (mapcar (lambda (h)
            (if (equal (plist-get h :id) id) updated h))
          hosts))

(defun skssh--delete-host (id hosts)
  "Remove host with :id = ID from HOSTS. Returns new list."
  (cl-remove id hosts :test #'equal
             :key (lambda (h) (plist-get h :id))))

(defun skssh--parse-ssh-config (&optional config-file)
  "Parse CONFIG-FILE (default: ~/.ssh/config) into a list of host plists.
Skips wildcard Host blocks (containing * or ?)."
  (let ((file (or config-file (expand-file-name "~/.ssh/config")))
        hosts
        current-host)
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (string-trim (buffer-substring-no-properties
                                    (line-beginning-position)
                                    (line-end-position)))))
            (cond
             ((string-match "\\`Host[[:space:]]+\\(.*\\)\\'" line)
              (when current-host
                (unless (string-match-p "[*?]" (plist-get current-host :host))
                  (push current-host hosts)))
              (let ((name (string-trim (match-string 1 line))))
                (setq current-host (list :id       (skssh--generate-id)
                                         :label    name
                                         :host     name
                                         :user     (user-login-name)
                                         :port     22
                                         :identity nil
                                         :groups   nil
                                         :notes    ""))))
             ((string-match "\\`HostName[[:space:]]+\\(.*\\)\\'" line)
              (when current-host
                (setq current-host
                      (plist-put current-host :host (string-trim (match-string 1 line))))))
             ((string-match "\\`User[[:space:]]+\\(.*\\)\\'" line)
              (when current-host
                (setq current-host
                      (plist-put current-host :user (string-trim (match-string 1 line))))))
             ((string-match "\\`Port[[:space:]]+\\(.*\\)\\'" line)
              (when current-host
                (setq current-host
                      (plist-put current-host :port
                                 (string-to-number (string-trim (match-string 1 line)))))))
             ((string-match "\\`IdentityFile[[:space:]]+\\(.*\\)\\'" line)
              (when current-host
                (setq current-host
                      (plist-put current-host :identity
                                 (expand-file-name
                                  (string-trim (match-string 1 line)))))))))
          (forward-line 1))
        (when current-host
          (unless (string-match-p "[*?]" (plist-get current-host :host))
            (push current-host hosts)))))
    (nreverse hosts)))

;;;###autoload
(defun skssh-import-from-ssh-config ()
  "One-time import of hosts from ~/.ssh/config into skssh.
Existing hosts with the same label are skipped."
  (interactive)
  (let* ((imported (skssh--parse-ssh-config))
         (existing (skssh--load-hosts))
         (existing-labels (mapcar (lambda (h) (plist-get h :label)) existing))
         (new-hosts (cl-remove-if
                     (lambda (h) (member (plist-get h :label) existing-labels))
                     imported))
         (merged (append existing new-hosts)))
    (skssh--save-hosts merged)
    (message "skssh: imported %d host(s) from ~/.ssh/config (%d skipped, already exist)"
             (length new-hosts)
             (- (length imported) (length new-hosts)))))

(provide 'skssh-config)

;; Local Variables:
;; package-lint-main-file: "skssh.el"
;; End:
;;; skssh-config.el ends here
