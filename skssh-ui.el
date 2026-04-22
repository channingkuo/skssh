;;; skssh-ui.el --- Host list UI and Transient menus  -*- lexical-binding: t; -*-
;;; Commentary:
;; tabulated-list-mode host browser and transient action menu.
;;; Code:

(require 'tabulated-list)
(require 'transient)
(require 'skssh-core)
(require 'cl-lib)

;;; Host list buffer

(defvar skssh-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'skssh-ui-open-transient)
    (define-key map (kbd "?")   #'skssh-ui-open-transient)
    (define-key map (kbd "s")   #'skssh-ui-connect-shell)
    (define-key map (kbd "d")   #'skssh-ui-connect-dired)
    (define-key map (kbd "f")   #'skssh-ui-open-sftp)
    (define-key map (kbd "e")   #'skssh-ui-edit-host)
    (define-key map (kbd "D")   #'skssh-ui-delete-host)
    (define-key map (kbd "a")   #'skssh-add-host)
    (define-key map (kbd "i")   #'skssh-import-from-ssh-config)
    (define-key map (kbd "G")   #'skssh-ui-filter-by-group)
    (define-key map (kbd "/")   #'skssh-ui-filter)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `skssh-list-mode'.")

(define-derived-mode skssh-list-mode tabulated-list-mode "skssh"
  "Major mode for browsing SSH hosts managed by skssh."
  (setq tabulated-list-format
        [("Label"   20 t)
         ("Host"    22 t)
         ("User"    10 t)
         ("Port"     6 t)
         ("Groups"  16 nil)
         ("Status"   6 nil)])
  (setq tabulated-list-sort-key '("Label" . nil))
  (tabulated-list-init-header)
  (add-hook 'tabulated-list-revert-hook #'skssh-ui--refresh nil t))

(defvar skssh-ui--group-filter nil
  "Current group filter string, or nil for no filter.")

(defvar skssh-ui--string-filter nil
  "Current substring filter against label/host/groups, or nil for no filter.")

(defun skssh-ui--host-status (host)
  "Return status indicator string for HOST plist."
  (if (skssh--session-active-p (plist-get host :id)) "●" "○"))

(defun skssh-ui--host-matches-string-p (host needle)
  "Return non-nil if HOST plist contains NEEDLE (case-insensitive).
Searches :label, :host, and any entry in :groups."
  (let ((case-fold-search t)
        (n (downcase needle)))
    (or (string-match-p (regexp-quote n)
                        (downcase (or (plist-get host :label) "")))
        (string-match-p (regexp-quote n)
                        (downcase (or (plist-get host :host)  "")))
        (cl-some (lambda (g)
                   (string-match-p (regexp-quote n) (downcase g)))
                 (or (plist-get host :groups) nil)))))

(defun skssh-ui--host-to-row (host)
  "Convert HOST plist to tabulated-list row entry."
  (list (plist-get host :id)
        (vector
         (or (plist-get host :label) "")
         (or (plist-get host :host)  "")
         (or (plist-get host :user)  "")
         (number-to-string (or (plist-get host :port) 22))
         (mapconcat #'identity (or (plist-get host :groups) nil) " ")
         (skssh-ui--host-status host))))

(defun skssh-ui--refresh ()
  "Reload hosts and repopulate the list buffer."
  (let* ((hosts (skssh--load-hosts))
         (after-group (if skssh-ui--group-filter
                          (cl-remove-if-not
                           (lambda (h)
                             (member skssh-ui--group-filter
                                     (plist-get h :groups)))
                           hosts)
                        hosts))
         (filtered (if skssh-ui--string-filter
                       (cl-remove-if-not
                        (lambda (h)
                          (skssh-ui--host-matches-string-p
                           h skssh-ui--string-filter))
                        after-group)
                     after-group)))
    (setq tabulated-list-entries (mapcar #'skssh-ui--host-to-row filtered))
    (tabulated-list-print t)
    (skssh-ui--update-header-line)))

(defun skssh-ui--update-header-line ()
  "Show active filters in the header line, or clear it."
  (let ((parts (delq nil
                     (list (when skssh-ui--group-filter
                             (format "group=%s" skssh-ui--group-filter))
                           (when skssh-ui--string-filter
                             (format "match=\"%s\"" skssh-ui--string-filter))))))
    (setq header-line-format
          (when parts
            (concat "skssh filter: " (mapconcat #'identity parts " | ")
                   "   (press / to change, G for group, / with empty input to clear)")))))

(defun skssh-ui--current-host ()
  "Return host plist for the row at point, or signal error."
  (let* ((id (tabulated-list-get-id))
         (hosts (skssh--load-hosts)))
    (or (skssh--get-host id hosts)
        (user-error "No host at point"))))

(defun skssh-ui-filter-by-group ()
  "Prompt for a group name and filter the host list."
  (interactive)
  (let* ((hosts (skssh--load-hosts))
         (all-groups (delete-dups
                      (apply #'append
                             (mapcar (lambda (h) (plist-get h :groups)) hosts))))
         (choice (completing-read "Filter by group (empty = all): "
                                  all-groups nil nil)))
    (setq skssh-ui--group-filter (if (string-empty-p choice) nil choice))
    (skssh-ui--refresh)))

(defun skssh-ui-filter (needle)
  "Filter host list by substring NEEDLE (matched against label/host/groups).
Empty input clears the filter."
  (interactive
   (list (read-string
          (format "Filter (label/host/group%s, empty = clear): "
                  (if skssh-ui--string-filter
                      (format ", current=\"%s\"" skssh-ui--string-filter)
                    "")))))
  (setq skssh-ui--string-filter
        (if (or (null needle) (string-empty-p needle)) nil needle))
  (skssh-ui--refresh)
  (if skssh-ui--string-filter
      (message "skssh: filter = \"%s\" (%d match)"
               skssh-ui--string-filter
               (length tabulated-list-entries))
    (message "skssh: filter cleared")))

(defun skssh-ui-connect-shell ()
  "Open shell for host at point."
  (interactive)
  (skssh--connect-shell (skssh-ui--current-host)))

(defun skssh-ui-connect-dired ()
  "Open dired for host at point."
  (interactive)
  (skssh--connect-dired (skssh-ui--current-host)))

(defun skssh-ui-open-sftp ()
  "Open SFTP dual-pane for host at point."
  (interactive)
  (skssh-sftp-open (skssh-ui--current-host)))

(defun skssh-ui-delete-host ()
  "Delete host at point after confirmation."
  (interactive)
  (let* ((host (skssh-ui--current-host))
         (label (plist-get host :label)))
    (when (yes-or-no-p (format "Delete host \"%s\"? " label))
      (let* ((hosts (skssh--load-hosts))
             (new   (skssh--delete-host (plist-get host :id) hosts)))
        (skssh--save-hosts new)
        (skssh-ui--refresh)
        (message "skssh: deleted \"%s\"" label)))))

(defun skssh-ui-edit-host ()
  "Edit host at point via minibuffer prompts."
  (interactive)
  (let* ((host (skssh-ui--current-host))
         (label    (read-string "Label: "    (plist-get host :label)))
         (hostname (read-string "Host: "     (plist-get host :host)))
         (user     (read-string "User: "     (plist-get host :user)))
         (port     (read-number "Port: "     (plist-get host :port)))
         (identity (read-string "Identity (blank = auth-source): "
                                (or (plist-get host :identity) "")))
         (groups-str (read-string "Groups (space-separated): "
                                  (mapconcat #'identity
                                             (plist-get host :groups) " ")))
         (updated (list :id       (plist-get host :id)
                        :label    label
                        :host     hostname
                        :user     user
                        :port     port
                        :identity (if (string-empty-p identity) nil identity)
                        :groups   (split-string groups-str " " t)
                        :notes    (or (plist-get host :notes) "")))
         (hosts (skssh--load-hosts))
         (new   (skssh--update-host (plist-get host :id) updated hosts)))
    (skssh--save-hosts new)
    (skssh-ui--refresh)
    (message "skssh: updated \"%s\"" label)))

;;; Forward declarations (defined in skssh.el and skssh-sftp.el)
(declare-function skssh-add-host "skssh")
(declare-function skssh-import-from-ssh-config "skssh")
(declare-function skssh-sftp-open "skssh-sftp")

;;; Transient menu

(transient-define-prefix skssh-ui-open-transient ()
  "Transient menu for skssh host actions."
  [:description
   (lambda ()
     (if-let ((host (ignore-errors (skssh-ui--current-host))))
         (format "skssh: %s (%s)"
                 (plist-get host :label)
                 (plist-get host :host))
       "skssh"))
   ["Connect"
    ("s" "Shell"      skssh-ui-connect-shell)
    ("d" "Dired"      skssh-ui-connect-dired)
    ("f" "SFTP"  skssh-ui-open-sftp)]
   ["Edit"
    ("e" "Edit Host"   skssh-ui-edit-host)
    ("D" "Delete Host" skssh-ui-delete-host)]
   ["Filter"
    ("/" "Search label/host/group" skssh-ui-filter)
    ("G" "Filter by group"         skssh-ui-filter-by-group)]
   ["Navigate"
    ("q" "Quit"       quit-window)]])

(provide 'skssh-ui)
;;; skssh-ui.el ends here
