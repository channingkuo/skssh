;;; skssh.el --- SSH connection manager  -*- lexical-binding: t; -*-
;; Author: ChanningKuo
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.0"))
;; Keywords: ssh tramp tools
;;; Commentary:
;; Manage SSH connections from Emacs.
;;; Code:

(require 'skssh-config)
(require 'skssh-core)
(require 'skssh-ui)
(require 'skssh-sftp)
(require 'cl-lib)

;;;###autoload
(defun skssh ()
  "Open the skssh host list buffer."
  (interactive)
  (let ((buf (get-buffer-create "*skssh*")))
    (with-current-buffer buf
      (skssh-list-mode)
      (skssh-ui--refresh))
    (switch-to-buffer buf)))

;;;###autoload
(defun skssh-add-host ()
  "Add a new SSH host interactively."
  (interactive)
  (let* ((label    (read-string "Label: "))
         (hostname (read-string "Host (IP or domain): "))
         (user     (read-string "User: " (user-login-name)))
         (port     (read-number "Port: " 22))
         (identity (read-string "Identity file (blank = auth-source): "))
         (groups-str (read-string "Groups (space-separated, optional): "))
         (shell    (read-string "Shell (blank = default /bin/bash): "))
         (shell-args-str (read-string
                          "Shell args (space-separated, blank = default -l -i): "))
         (host (list :label      label
                     :host       hostname
                     :user       user
                     :port       port
                     :identity   (if (string-empty-p identity) nil identity)
                     :groups     (split-string groups-str " " t)
                     :shell      (if (string-empty-p shell) nil shell)
                     :shell-args (if (string-empty-p shell-args-str)
                                     nil
                                   (split-string shell-args-str " " t))
                     :notes      ""))
         (hosts  (skssh--load-hosts))
         (new    (skssh--add-host host hosts)))
    (skssh--save-hosts new)
    (message "skssh: added \"%s\"" label)
    (when (get-buffer "*skssh*")
      (with-current-buffer "*skssh*"
        (skssh-ui--refresh)))))

;;;###autoload
(defun skssh-sftp (host-label)
  "Open SFTP dual-pane for a host selected by HOST-LABEL."
  (interactive
   (list (completing-read "Host: "
                          (mapcar (lambda (h) (plist-get h :label))
                                  (skssh--load-hosts)))))
  (let* ((hosts (skssh--load-hosts))
         (host  (cl-find host-label hosts :test #'equal
                         :key (lambda (h) (plist-get h :label)))))
    (if host
        (skssh-sftp-open host)
      (user-error "Host \"%s\" not found" host-label))))

(provide 'skssh)
;;; skssh.el ends here
