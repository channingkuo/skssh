;;; skssh.el --- SSH connection manager  -*- lexical-binding: t; -*-

;; Author: ChanningKuo <channingkuo@icloud.com>
;; Maintainer: ChanningKuo <channingkuo@icloud.com>
;; Version: 0.1.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: ssh tramp tools
;; URL: https://github.com/ChanningKuo/skssh

;;; Commentary:

;; skssh is an SSH connection manager for Emacs.  It provides a
;; tabulated host list where you can add, edit, delete, and connect to
;; SSH hosts without leaving Emacs.
;;
;; Connections use TRAMP under the hood, so you get full Emacs
;; integration: Dired, shell buffers, and file editing all work over
;; SSH out of the box.
;;
;; A built-in dual-pane SFTP interface lets you transfer files between
;; local and remote directories, with drag-and-drop support in
;; terminal Emacs.
;;
;; Host configuration is stored in `user-emacs-directory'/skssh/hosts.el
;; and never touches ~/.ssh/config.  You can import existing hosts
;; from ~/.ssh/config as a one-time operation.
;;
;; Main entry points:
;;   M-x skssh          — open host list
;;   M-x skssh-add-host — add a new host interactively
;;   M-x skssh-sftp     — open SFTP dual-pane for a host
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
