;;; skssh-test.el --- ERT tests for skssh  -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'skssh-config)
(require 'skssh-core)
(require 'skssh-sftp)
(require 'skssh-ui)

;;; Config tests

(defmacro skssh-test--with-temp-config (&rest body)
  "Run BODY with skssh-config-file bound to a temp file."
  `(let* ((tmp (make-temp-file "skssh-test-hosts" nil ".el"))
          (skssh-config-file tmp))
     (unwind-protect
         (progn ,@body)
       (delete-file tmp))))

(ert-deftest skssh-test-load-hosts-empty ()
  "Loading non-existent hosts.el returns nil."
  (let ((skssh-config-file "/tmp/skssh-nonexistent-99999.el"))
    (should (null (skssh--load-hosts)))))

(ert-deftest skssh-test-save-and-load-hosts ()
  "Saved hosts round-trip through load."
  (skssh-test--with-temp-config
   (let ((hosts (list '(:id "abc" :label "Box" :host "1.2.3.4"
                        :user "root" :port 22 :identity nil
                        :groups ("prod") :notes ""))))
     (skssh--save-hosts hosts)
     (should (equal hosts (skssh--load-hosts))))))

(ert-deftest skssh-test-add-host-assigns-id ()
  "skssh--add-host assigns :id when missing."
  (let* ((host '(:label "Box" :host "1.2.3.4" :user "root"
                 :port 22 :identity nil :groups nil :notes ""))
         (result (skssh--add-host host nil)))
    (should (= 1 (length result)))
    (should (stringp (plist-get (car result) :id)))))

(ert-deftest skssh-test-get-host-by-id ()
  "skssh--get-host returns correct host plist."
  (let ((hosts '((:id "aaa" :label "A" :host "h1" :user "u" :port 22
                  :identity nil :groups nil :notes "")
                 (:id "bbb" :label "B" :host "h2" :user "u" :port 22
                  :identity nil :groups nil :notes ""))))
    (should (equal "A" (plist-get (skssh--get-host "aaa" hosts) :label)))
    (should (null (skssh--get-host "zzz" hosts)))))

(ert-deftest skssh-test-update-host ()
  "skssh--update-host replaces the matching host."
  (let* ((hosts '((:id "aaa" :label "Old" :host "h1" :user "u" :port 22
                   :identity nil :groups nil :notes "")))
         (updated '(:id "aaa" :label "New" :host "h1" :user "u" :port 22
                    :identity nil :groups nil :notes ""))
         (result (skssh--update-host "aaa" updated hosts)))
    (should (equal "New" (plist-get (car result) :label)))))

(ert-deftest skssh-test-delete-host ()
  "skssh--delete-host removes matching host."
  (let* ((hosts '((:id "aaa" :label "A" :host "h1" :user "u" :port 22
                   :identity nil :groups nil :notes "")
                  (:id "bbb" :label "B" :host "h2" :user "u" :port 22
                   :identity nil :groups nil :notes "")))
         (result (skssh--delete-host "aaa" hosts)))
    (should (= 1 (length result)))
    (should (equal "bbb" (plist-get (car result) :id)))))

;;; SSH config import tests

(ert-deftest skssh-test-parse-ssh-config-basic ()
  "Parses a basic Host block with HostName, User, Port."
  (let* ((content "Host mybox\n  HostName 1.2.3.4\n  User deploy\n  Port 2222\n")
         (tmp (make-temp-file "skssh-ssh-config"))
         result)
    (unwind-protect
        (progn
          (with-temp-file tmp (insert content))
          (setq result (skssh--parse-ssh-config tmp))
          (should (= 1 (length result)))
          (let ((h (car result)))
            (should (equal "1.2.3.4" (plist-get h :host)))
            (should (equal "deploy"  (plist-get h :user)))
            (should (= 2222          (plist-get h :port)))))
      (delete-file tmp))))

(ert-deftest skssh-test-parse-ssh-config-skips-wildcard ()
  "Wildcard Host * blocks are skipped."
  (let* ((content "Host *\n  ServerAliveInterval 60\nHost realbox\n  HostName 9.9.9.9\n")
         (tmp (make-temp-file "skssh-ssh-config"))
         result)
    (unwind-protect
        (progn
          (with-temp-file tmp (insert content))
          (setq result (skssh--parse-ssh-config tmp))
          (should (= 1 (length result)))
          (should (equal "9.9.9.9" (plist-get (car result) :host))))
      (delete-file tmp))))

(ert-deftest skssh-test-parse-ssh-config-identity ()
  "IdentityFile is captured and expanded."
  (let* ((content "Host dev\n  HostName dev.example.com\n  User kuo\n  IdentityFile ~/.ssh/id_ed25519\n")
         (tmp (make-temp-file "skssh-ssh-config"))
         result)
    (unwind-protect
        (progn
          (with-temp-file tmp (insert content))
          (setq result (skssh--parse-ssh-config tmp))
          (should (stringp (plist-get (car result) :identity)))
          (should (string-match-p "id_ed25519" (plist-get (car result) :identity))))
      (delete-file tmp))))

;;; Core tests

(ert-deftest skssh-test-tramp-path-default-port ()
  "Standard port 22 omitted from TRAMP path."
  (let ((host '(:user "deploy" :host "1.2.3.4" :port 22)))
    (should (equal "/ssh:deploy@1.2.3.4:/"
                   (skssh--tramp-path host)))))

(ert-deftest skssh-test-tramp-path-custom-port ()
  "Non-standard port included as #PORT in TRAMP path."
  (let ((host '(:user "kuo" :host "dev.example.com" :port 2222)))
    (should (equal "/ssh:kuo@dev.example.com#2222:/"
                   (skssh--tramp-path host)))))

(ert-deftest skssh-test-tramp-path-with-remote-path ()
  "Remote path appended correctly."
  (let ((host '(:user "root" :host "10.0.0.1" :port 22)))
    (should (equal "/ssh:root@10.0.0.1:/var/log"
                   (skssh--tramp-path host "/var/log")))))

(ert-deftest skssh-test-session-tracking ()
  "skssh--session-register and skssh--session-active-p work together."
  (let ((skssh--active-sessions (make-hash-table :test 'equal))
        (buf (generate-new-buffer "*skssh-test-session*")))
    (unwind-protect
        (progn
          (skssh--session-register "test-id" buf)
          (should (skssh--session-active-p "test-id"))
          (skssh--session-remove "test-id")
          (should-not (skssh--session-active-p "test-id")))
      (kill-buffer buf))))

;;; SFTP tests

(ert-deftest skssh-test-sftp-path-regexp-unix ()
  "Unix absolute path matches sftp path regexp."
  (should (string-match-p skssh-sftp--path-regexp "/home/user/file.txt"))
  (should (string-match-p skssh-sftp--path-regexp "~/Documents/report.pdf")))

(ert-deftest skssh-test-sftp-path-regexp-windows ()
  "Windows drive paths match sftp path regexp."
  (should (string-match-p skssh-sftp--path-regexp "C:/Users/kuo/file.txt"))
  (should (string-match-p skssh-sftp--path-regexp "D:\\Projects\\app.zip")))

(ert-deftest skssh-test-sftp-path-regexp-rejects-plain-text ()
  "Plain text does not match sftp path regexp."
  (should-not (string-match-p skssh-sftp--path-regexp "hello world"))
  (should-not (string-match-p skssh-sftp--path-regexp "relative/path")))

(ert-deftest skssh-test-sftp-transfer-direction-upload ()
  "Upload when selected window is the remote (right) window."
  (let* ((left  (selected-window))
         (right (split-window-right)))
    (unwind-protect
        (progn
          (select-window right)
          (should (eq 'upload
                      (skssh-sftp--transfer-direction left right))))
      (delete-window right))))

(ert-deftest skssh-test-sftp-transfer-direction-download ()
  "Download when selected window is the local (left) window."
  (let* ((left  (selected-window))
         (right (split-window-right)))
    (unwind-protect
        (progn
          (select-window left)
          (should (eq 'download
                      (skssh-sftp--transfer-direction left right))))
      (delete-window right))))

;;; UI filter tests

(ert-deftest skssh-test-ui-filter-matches-label ()
  "Substring filter matches a host's label (case-insensitive)."
  (let ((host '(:id "a" :label "Production Web" :host "1.2.3.4"
                :user "u" :port 22 :groups ("prod"))))
    (should (skssh-ui--host-matches-string-p host "prod"))
    (should (skssh-ui--host-matches-string-p host "WEB"))))

(ert-deftest skssh-test-ui-filter-matches-host ()
  "Substring filter matches :host."
  (let ((host '(:id "a" :label "Box" :host "dev.example.com"
                :user "u" :port 22 :groups nil)))
    (should (skssh-ui--host-matches-string-p host "example"))))

(ert-deftest skssh-test-ui-filter-matches-group ()
  "Substring filter matches any entry in :groups."
  (let ((host '(:id "a" :label "Box" :host "h"
                :user "u" :port 22 :groups ("staging" "eu"))))
    (should (skssh-ui--host-matches-string-p host "stag"))
    (should (skssh-ui--host-matches-string-p host "eu"))))

(ert-deftest skssh-test-ui-filter-rejects-miss ()
  "Substring filter returns nil when nothing matches."
  (let ((host '(:id "a" :label "Box" :host "h"
                :user "u" :port 22 :groups ("prod"))))
    (should-not (skssh-ui--host-matches-string-p host "zzz"))))

(provide 'skssh-test)
;;; skssh-test.el ends here
