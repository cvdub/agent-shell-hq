;;; agent-shell-hq-toggle-test.el --- Workspace recovery tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agent-shell-hq-toggle)

(defmacro agent-shell-hq-test--with-workspace (&rest body)
  "Run BODY with isolated perspectives and no agent processes."
  (declare (indent 0))
  `(let ((persp-auto-resume-time -1)
         (persp-auto-save-opt 0)
         (state (window-state-get nil t)))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-shell-hq-peek--grouped-buffers)
                    (lambda () nil)))
           (persp-mode 1)
           (persp-switch "hq-test-origin")
           ,@body)
       (agent-shell-hq-toggle--teardown)
       (persp-mode -1)
       (window-state-put state (frame-root-window) 'safe))))

(ert-deftest agent-shell-hq-toggle-rebuilds-missing-sidebar ()
  (agent-shell-hq-test--with-workspace
    (agent-shell-hq-toggle)
    (let ((old-timer agent-shell-hq-toggle--refresh-timer))
      (delete-window (get-buffer-window agent-shell-hq-toggle--sidebar-name))
      (agent-shell-hq-toggle)
      (should (equal (safe-persp-name (get-current-persp))
                     agent-shell-hq-toggle--persp-name))
      (should (window-live-p (get-buffer-window agent-shell-hq-toggle--sidebar-name)))
      (should-not (memq old-timer timer-list))
      (should (memq agent-shell-hq-toggle--refresh-timer timer-list))
      (agent-shell-hq-toggle)
      (should (equal (safe-persp-name (get-current-persp)) "hq-test-origin"))
      (should-not agent-shell-hq-toggle--refresh-timer))))

(ert-deftest agent-shell-hq-toggle-rolls-back-failed-setup ()
  (agent-shell-hq-test--with-workspace
    (cl-letf (((symbol-function 'agent-shell-hq-toggle--render)
               (lambda () (error "Test render failure"))))
      (should-error (agent-shell-hq-toggle)))
    (should (equal (safe-persp-name (get-current-persp)) "hq-test-origin"))
    (should-not (get-buffer-window agent-shell-hq-toggle--sidebar-name))
    (should-not agent-shell-hq-toggle--main-window)
    (should-not agent-shell-hq-toggle--refresh-timer)
    ;; A subsequent attempt must work without manual cleanup.
    (agent-shell-hq-toggle)
    (should (window-live-p (get-buffer-window agent-shell-hq-toggle--sidebar-name)))))

(ert-deftest agent-shell-hq-toggle-rolls-back-sidebar-lost-during-setup ()
  (agent-shell-hq-test--with-workspace
    (let ((render (symbol-function 'agent-shell-hq-toggle--render)))
      (cl-letf (((symbol-function 'agent-shell-hq-toggle--render)
                 (lambda ()
                   (funcall render)
                   (delete-window
                    (get-buffer-window agent-shell-hq-toggle--sidebar-name)))))
        (should-error (agent-shell-hq-toggle) :type 'user-error)))
    (should (equal (safe-persp-name (get-current-persp)) "hq-test-origin"))
    (should-not agent-shell-hq-toggle--refresh-timer)))

;;; agent-shell-hq-toggle-test.el ends here
