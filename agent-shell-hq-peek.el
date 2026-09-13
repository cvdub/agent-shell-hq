;;; agent-shell-hq-peek.el --- Posframe buffer switcher for agent-shell  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1") (posframe "1.4"))

;;; Code:

(require 'agent-shell)
(require 'agent-shell-viewport)
(require 'posframe)

;;;; Customization

(defgroup agent-shell-hq-peek nil
  "Posframe buffer switcher for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-hq-peek-")

(defcustom agent-shell-hq-peek-position 'right
  "Edge of the frame where the peek posframe is anchored.
One of `top', `bottom', `left', `right'."
  :type '(choice (const top) (const bottom) (const left) (const right)))

(defcustom agent-shell-hq-peek-width 52
  "Width of the peek posframe in columns."
  :type 'integer)

(defcustom agent-shell-hq-peek-height 60
  "Maximum height of the peek posframe in rows."
  :type 'integer)

(defcustom agent-shell-hq-peek-parameters nil
  "Extra frame parameters used by the peek posframe.
Passed through to `posframe-show' as its OVERRIDE-PARAMETERS
argument, e.g. to set (background-color . \"black\")."
  :type '(alist :key-type symbol :value-type sexp))

;;;; Faces

(defface agent-shell-hq-peek-project
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for project group headers in the peek posframe.")

;;;; Internal state

(defconst agent-shell-hq-peek--buffer-name " *agent-shell-hq-peek*")

(defvar agent-shell-hq-peek--entries nil
  "Flat list of selectable entries.  Each element: plist (:buffer SHELL-BUF).")

(defvar agent-shell-hq-peek--current-idx 0
  "Index into `agent-shell-hq-peek--entries' of the highlighted entry.")

(defvar agent-shell-hq-peek--origin-window nil
  "Window that was selected when peek was invoked.")

(defvar agent-shell-hq-peek--origin-buffer nil
  "Buffer displayed in the origin window when peek was invoked (restored on quit).")

(defvar agent-shell-hq-peek--saved-terminal-map nil
  "Saved `overriding-terminal-local-map' value, restored when peek is dismissed.")

;; Minimal override map — only C-g, so normal editing is unaffected in the
;; parent frame. `overriding-terminal-local-map' has the highest priority and
;; fires before the child-frame keymap lookup, making C-g reliable regardless
;; of which frame currently has focus.
(defvar agent-shell-hq-peek--quit-override-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-g") #'agent-shell-hq-peek-quit)
    map)
  "Terminal-wide override map active while the peek posframe is shown.")

;;;; Keymap

(defvar agent-shell-hq-peek-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "n")   #'agent-shell-hq-peek-next)
    (define-key map (kbd "j")   #'agent-shell-hq-peek-next)
    (define-key map (kbd "p")   #'agent-shell-hq-peek-prev)
    (define-key map (kbd "k")   #'agent-shell-hq-peek-prev)
    (define-key map (kbd "RET") #'agent-shell-hq-peek-select)
    (define-key map (kbd "g")   #'agent-shell-hq-peek-quit)
    (define-key map (kbd "q")   #'agent-shell-hq-peek-quit)
    (define-key map (kbd "C-g") #'agent-shell-hq-peek-quit)
    (define-key map (kbd "s")   #'agent-shell-hq-peek-new-shell)
    map)
  "Keymap active inside the agent-shell-hq peek posframe.")

;;;; Override map helpers

(defun agent-shell-hq-peek--clear-override ()
  "Restore `overriding-terminal-local-map' to its pre-peek value."
  (when (eq overriding-terminal-local-map agent-shell-hq-peek--quit-override-map)
    (setq overriding-terminal-local-map agent-shell-hq-peek--saved-terminal-map))
  (setq agent-shell-hq-peek--saved-terminal-map nil))

;;;; Preferred display buffer

(defun agent-shell-hq-peek--preferred-buffer (shell-buf)
  "Return the best buffer to display for SHELL-BUF.
Uses the existing viewport buffer when one already exists, so its mode
\(view or edit) is preserved.  Falls back to the shell buffer itself."
  (or (ignore-errors
        (agent-shell-viewport--buffer :shell-buffer shell-buf :existing-only t))
      shell-buf))

;;;; Preview

(defun agent-shell-hq-peek--preview-current ()
  "Show the highlighted buffer in the origin window (behind the posframe)."
  (when-let* ((entry      (nth agent-shell-hq-peek--current-idx
                               agent-shell-hq-peek--entries))
              (shell-buf  (plist-get entry :buffer))
              (display-buf (agent-shell-hq-peek--preferred-buffer shell-buf)))
    (when (and (window-live-p agent-shell-hq-peek--origin-window)
               (buffer-live-p display-buf))
      (set-window-buffer agent-shell-hq-peek--origin-window display-buf))))

;;;; SVG icon files

(defvar agent-shell-hq-peek--icon-cache nil
  "Alist of (STATE . IMAGE) for buffer status icons.")

(defvar agent-shell-hq-peek--busy-frames nil
  "Vector of cached Lucide activity signal images.")

(defconst agent-shell-hq-peek--icon-sizes
  '((idle . 14) (busy . 14) (blocked . 14) (dead . 12))
  "Per-state image sizes in pixels, matching icons/ and the embedded SVGs.")

(defconst agent-shell-hq-peek--busy-frame-count 60
  "Number of frames in the three-second activity animation at 20fps.")

(defconst agent-shell-hq-peek--busy-path-length 49.214485
  "Length of Lucide's activity path in SVG user units.
Measured from icons/busy.svg; update if the activity path changes.
Explicit dash lengths avoid depending on SVG pathLength support.")

(defvar-local agent-shell-hq-peek--animation-timer nil
  "Timer animating busy icons in this HQ buffer.")

(defvar-local agent-shell-hq-peek--animation-frame 0
  "Current busy animation frame in this HQ buffer.")

(defconst agent-shell-hq-peek--icon-svgs
  '((idle . "<svg
  xmlns=\"http://www.w3.org/2000/svg\"
  width=\"14\"
  height=\"14\"
  viewBox=\"2 2 20 20\"
  fill=\"none\"
  stroke=\"#4E9A72\"
  stroke-width=\"4\"
  stroke-linecap=\"round\"
  stroke-linejoin=\"round\"
>
  <path d=\"M20 6 9 17l-5-5\" />
</svg>")
    (busy . "<svg
  xmlns=\"http://www.w3.org/2000/svg\"
  width=\"14\"
  height=\"14\"
  viewBox=\"1 1 22 22\"
  fill=\"none\"
  stroke=\"#C9922A\"
  stroke-width=\"3.5\"
  stroke-linecap=\"round\"
  stroke-linejoin=\"round\"
>
  <path d=\"M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2\" />
</svg>")
    (blocked . "<svg
  xmlns=\"http://www.w3.org/2000/svg\"
  width=\"14\"
  height=\"14\"
  viewBox=\"1 1 22 22\"
  fill=\"none\"
  stroke=\"#C0392B\"
  stroke-width=\"3\"
  stroke-linecap=\"round\"
  stroke-linejoin=\"round\"
>
  <path d=\"M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719\" />
  <path d=\"M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3\" />
  <path d=\"M12 17h.01\" />
</svg>")
    (dead . "<svg
  xmlns=\"http://www.w3.org/2000/svg\"
  width=\"12\"
  height=\"12\"
  viewBox=\"4 4 16 16\"
  fill=\"none\"
  stroke=\"#C0392B\"
  stroke-width=\"3\"
  stroke-linecap=\"round\"
  stroke-linejoin=\"round\"
>
  <path d=\"M18 6 6 18\" />
  <path d=\"m6 6 12 12\" />
</svg>"))
  "Lucide SVGs matching icons/.  See icons/LICENSE for attribution.")

;; Reloading the module should also pick up changes to the embedded SVGs.
(setq agent-shell-hq-peek--icon-cache nil
      agent-shell-hq-peek--busy-frames nil)

(defun agent-shell-hq-peek--create-icon-image (svg state)
  "Create SVG for STATE, centered in a shared fixed-width icon column."
  (let* ((size (alist-get state agent-shell-hq-peek--icon-sizes))
         (column-width (apply #'max (mapcar #'cdr agent-shell-hq-peek--icon-sizes))))
    ;; Horizontal margins make every image occupy the same width, while
    ;; preserving each glyph's chosen size.  Dimensions are already pixels.
    (create-image svg 'svg t :width size :height size :ascent 'center
                  :margin (cons (/ (- column-width size) 2) 0) :scale 1.0)))

(defun agent-shell-hq-peek--svg-icon (state)
  "Return the cached SVG image for STATE (`busy', `blocked', `idle', or `dead')."
  (unless agent-shell-hq-peek--icon-cache
    (setq agent-shell-hq-peek--icon-cache
          (mapcar (lambda (pair)
                    (cons (car pair)
                          (agent-shell-hq-peek--create-icon-image (cdr pair) (car pair))))
                  agent-shell-hq-peek--icon-svgs)))
  (alist-get state agent-shell-hq-peek--icon-cache))

(defcustom agent-shell-hq-fallback-icons
  '((idle . ("✓" . success))
    (busy . ("◔" . warning))
    (blocked . ("⚠" . error))
    (dead . ("✗" . error)))
  "Fallback Unicode characters for TUI Emacs.
Each entry is (STATE . (CHAR . FACE)), used when image display is
unavailable (e.g. terminal Emacs).  Uses `font-lock-face' so the
color survives outer `face' text properties in the render code."
  :type '(alist :key-type (choice (const idle) (const busy) (const blocked) (const dead))
                :value-type (cons string face))
  :group 'agent-shell-hq-peek)

(defun agent-shell-hq--icon (state &optional buffer)
  "Return a propertized string displaying the icon for STATE.
In GUI Emacs with SVG support, this is a space with a `display' SVG
image property.  Otherwise, this is a Unicode character with a face.
BUFFER is the source session, used to stop animation when it stops being busy."
  (if (and (display-graphic-p) (image-type-available-p 'svg))
      (propertize " " 'display (agent-shell-hq-peek--svg-icon state)
                  'agent-shell-hq-peek-busy-icon
                  (and (eq state 'busy) (or buffer t)))
    (let ((fallback (or (alist-get state agent-shell-hq-fallback-icons)
                         '("?" . default))))
      (propertize (car fallback) 'face (cdr fallback) 'font-lock-face (cdr fallback)))))

(defun agent-shell-hq-peek--busy-frame (index)
  "Return cached activity frame INDEX with a traveling signal highlight."
  (unless agent-shell-hq-peek--busy-frames
    (setq agent-shell-hq-peek--busy-frames
          (vconcat
           (mapcar
            (lambda (step)
              (let* ((svg (alist-get 'busy agent-shell-hq-peek--icon-svgs))
                     (start (1+ (string-match ">" svg)))
                     (end (string-match "</svg>" svg))
                     (path (substring svg start end))
                     (length agent-shell-hq-peek--busy-path-length)
                     (offset (* length (- (/ (float step)
                                              agent-shell-hq-peek--busy-frame-count)
                                           1))))
                (agent-shell-hq-peek--create-icon-image
                 (concat (substring svg 0 start)
                         "<g opacity=\"0.3\">" path "</g>"
                         (format "<g stroke-dasharray=\"%.6f %.6f\" stroke-dashoffset=\"%.6f\">"
                                 (* length 0.22) (* length 0.78) offset)
                         path "</g></svg>") 'busy)))
            (number-sequence 0 (1- agent-shell-hq-peek--busy-frame-count))))))
  (aref agent-shell-hq-peek--busy-frames index))

(defun agent-shell-hq-peek--stop-animation ()
  "Cancel this HQ buffer's animation timer."
  (when (timerp agent-shell-hq-peek--animation-timer)
    (cancel-timer agent-shell-hq-peek--animation-timer))
  (setq agent-shell-hq-peek--animation-timer nil))

(defun agent-shell-hq-peek--animate (buffer)
  "Advance only busy icons in BUFFER when it is visible."
  (save-match-data
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (get-buffer-window buffer 'visible)
          (setq agent-shell-hq-peek--animation-frame
                (mod (1+ agent-shell-hq-peek--animation-frame)
                     agent-shell-hq-peek--busy-frame-count))
          (with-silent-modifications
            (let ((pos (point-min)))
              (while (< pos (point-max))
                (when-let ((source (get-text-property pos 'agent-shell-hq-peek-busy-icon)))
                  (let ((state (if (bufferp source)
                                   (agent-shell-hq-peek--buffer-state source)
                                 'busy)))
                    (put-text-property
                     pos (1+ pos) 'display
                     (if (eq state 'busy)
                         (agent-shell-hq-peek--busy-frame agent-shell-hq-peek--animation-frame)
                       (agent-shell-hq-peek--svg-icon state)))
                    (unless (eq state 'busy)
                      (remove-text-properties pos (1+ pos)
                                              '(agent-shell-hq-peek-busy-icon nil)))))
                (setq pos (next-single-property-change
                           pos 'agent-shell-hq-peek-busy-icon nil (point-max))))))
          (unless (text-property-not-all (point-min) (point-max)
                                         'agent-shell-hq-peek-busy-icon nil)
            (agent-shell-hq-peek--stop-animation)))))))

(defun agent-shell-hq-peek--sync-animation ()
  "Start or stop animation to match the busy icons in this HQ buffer."
  (if (text-property-not-all (point-min) (point-max)
                             'agent-shell-hq-peek-busy-icon nil)
      (unless (timerp agent-shell-hq-peek--animation-timer)
        (add-hook 'kill-buffer-hook #'agent-shell-hq-peek--stop-animation nil t)
        (setq agent-shell-hq-peek--animation-timer
              (run-with-timer 0.05 0.05 #'agent-shell-hq-peek--animate (current-buffer))))
    (agent-shell-hq-peek--stop-animation)))

(defun agent-shell-hq-peek--buffer-state (buf)
  "Return `busy', `blocked', `idle', or `dead' for BUF."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (cond
         ((and (fboundp 'agent-shell-status)
               (eq (ignore-errors (agent-shell-status :shell-buffer buf)) 'blocked))
          'blocked)
         ((and (fboundp 'agent-shell--permission-pending-p)
               (ignore-errors (agent-shell--permission-pending-p :shell-buffer buf)))
          'blocked)
         ((shell-maker-busy) 'busy)
         (t 'idle)))
    'dead))

;;;; Buffer grouping

(defun agent-shell-hq-peek--grouped-buffers ()
  "Return list of (root project-name buffers) groups, sorted alphabetically."
  (let ((table (make-hash-table :test 'equal))
        (order nil))
    (dolist (buf (agent-shell-buffers))
      (let* ((root  (with-current-buffer buf (agent-shell-cwd)))
             (pname (with-current-buffer buf (agent-shell--project-name))))
        (unless (gethash root table)
          (puthash root (list pname nil) table)
          (push root order))
        (let ((entry (gethash root table)))
          (setcar (cdr entry) (append (cadr entry) (list buf))))))
    (let ((groups (mapcar (lambda (root)
                            (let ((e (gethash root table)))
                              (list root (car e)
                                    (sort (copy-sequence (cadr e))
                                          (lambda (a b)
                                            (string< (buffer-name a)
                                                     (buffer-name b)))))))
                          (nreverse order))))
      (sort groups (lambda (a b) (string< (cadr a) (cadr b)))))))

;;;; Rendering

(defun agent-shell-hq-peek--title-wrap-prefix (indent icon)
  "Return continuation spacing for a title after INDENT spaces and ICON."
  (concat (make-string indent ?\s)
          (if (eq (car-safe (get-text-property 0 'display icon)) 'image)
              ;; SVG margins reserve the same column for every state.
              (propertize " " 'display
                          `(space :width
                                  (,(apply #'max
                                           (mapcar #'cdr agent-shell-hq-peek--icon-sizes)))))
            (make-string (string-width icon) ?\s))
          " "))

(defun agent-shell-hq-peek--render (groups)
  "Render GROUPS into the peek buffer."
  (with-current-buffer (get-buffer-create agent-shell-hq-peek--buffer-name)
    (setq-local word-wrap t
                truncate-lines nil
                truncate-partial-width-windows nil)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq agent-shell-hq-peek--entries nil)
      (insert "\n")
      (dolist (group groups)
        (let ((pname (cadr  group))
              (bufs  (caddr group)))
          (insert (propertize (concat "    " pname "\n")
                              'face 'agent-shell-hq-peek-project
                              'agent-shell-hq-peek-header t))
           (dolist (buf bufs)
             (let* ((state (agent-shell-hq-peek--buffer-state buf))
                    (icon  (agent-shell-hq--icon state buf))
                    (bname (buffer-name buf)))
                (push (list :buffer buf) agent-shell-hq-peek--entries)
                (insert (propertize
                         (concat "      "
                                 icon
                                 " "
                                 bname
                                 "\n")
                        'agent-shell-hq-peek-buffer buf
                        'wrap-prefix (agent-shell-hq-peek--title-wrap-prefix 6 icon)))))
          (insert "\n")))
      (insert (propertize "    n/p navigate   RET select   q quit\n" 'face 'shadow))
      (insert "\n")
      (setq agent-shell-hq-peek--entries (nreverse agent-shell-hq-peek--entries))
      (setq buffer-read-only t))
    (goto-char (point-min))
    (agent-shell-hq-peek--sync-animation)))

;;;; Highlight management

(defvar agent-shell-hq-peek--highlight-overlay nil
  "Overlay used to highlight the selected line in the peek buffer.")

(defun agent-shell-hq-peek--highlight-line (idx)
  "Highlight the entry at IDX, clearing all others."
  (with-current-buffer (get-buffer-create agent-shell-hq-peek--buffer-name)
    (let ((inhibit-read-only t))
      (unless (overlayp agent-shell-hq-peek--highlight-overlay)
        (setq agent-shell-hq-peek--highlight-overlay
              (make-overlay (point-min) (point-min))))
      (let ((ov agent-shell-hq-peek--highlight-overlay))
        (move-overlay ov (point-min) (point-min))
        (when-let* ((entry (nth idx agent-shell-hq-peek--entries))
                    (buf   (plist-get entry :buffer))
                    (pos   (text-property-any (point-min) (point-max)
                                              'agent-shell-hq-peek-buffer buf)))
          (move-overlay ov pos
                        (min (1+ (save-excursion
                                   (goto-char pos)
                                   (line-end-position)))
                             (point-max)))
        (overlay-put ov 'face 'highlight))))))

;;;; Posframe position handler

(defun agent-shell-hq-peek--poshandler (info)
  "Anchor the posframe to `agent-shell-hq-peek-position'."
  (let* ((fw  (plist-get info :parent-frame-width))
         (fh  (plist-get info :parent-frame-height))
         (pw  (plist-get info :posframe-width))
         (ph  (plist-get info :posframe-height))
         (pad 8))
    (pcase agent-shell-hq-peek-position
      ('right  (cons (- fw pw pad) pad))
      ('left   (cons pad pad))
      ('top    (cons (/ (- fw pw) 2) pad))
      ('bottom (cons (/ (- fw pw) 2) (- fh ph pad))))))

;;;; Commands

(defun agent-shell-hq-peek-next ()
  "Move highlight to the next entry and preview that buffer."
  (interactive)
  (when agent-shell-hq-peek--entries
    (setq agent-shell-hq-peek--current-idx
          (mod (1+ agent-shell-hq-peek--current-idx)
               (length agent-shell-hq-peek--entries)))
    (agent-shell-hq-peek--highlight-line agent-shell-hq-peek--current-idx)
    (agent-shell-hq-peek--preview-current)))

(defun agent-shell-hq-peek-prev ()
  "Move highlight to the previous entry and preview that buffer."
  (interactive)
  (when agent-shell-hq-peek--entries
    (setq agent-shell-hq-peek--current-idx
          (mod (1- agent-shell-hq-peek--current-idx)
               (length agent-shell-hq-peek--entries)))
    (agent-shell-hq-peek--highlight-line agent-shell-hq-peek--current-idx)
    (agent-shell-hq-peek--preview-current)))

(defun agent-shell-hq-peek-select ()
  "Confirm the highlighted buffer, switch to it, and dismiss the posframe."
  (interactive)
  (when-let* ((entry     (nth agent-shell-hq-peek--current-idx
                              agent-shell-hq-peek--entries))
              (shell-buf (plist-get entry :buffer))
              (disp-buf  (agent-shell-hq-peek--preferred-buffer shell-buf)))
    (let ((win agent-shell-hq-peek--origin-window))
      (agent-shell-hq-peek--clear-override)
      (posframe-delete agent-shell-hq-peek--buffer-name)
      (when-let ((pb (get-buffer agent-shell-hq-peek--buffer-name)))
        (kill-buffer pb))
      (setq agent-shell-hq-peek--entries    nil
            agent-shell-hq-peek--current-idx 0)
      (when (and (window-live-p win) (buffer-live-p disp-buf))
        (select-window win)
        (switch-to-buffer disp-buf)
        (select-frame-set-input-focus (window-frame win))))))

(defun agent-shell-hq-peek-quit ()
  "Dismiss the peek posframe and restore the original buffer."
  (interactive)
  (agent-shell-hq-peek--clear-override)
  (let ((win      agent-shell-hq-peek--origin-window)
        (orig-buf agent-shell-hq-peek--origin-buffer))
    (posframe-delete agent-shell-hq-peek--buffer-name)
    (when-let ((buf (get-buffer agent-shell-hq-peek--buffer-name)))
      (kill-buffer buf))
    (setq agent-shell-hq-peek--entries      nil
          agent-shell-hq-peek--current-idx  0
          agent-shell-hq-peek--origin-buffer nil)
    (when (window-live-p win)
      (select-window win)
      (select-frame-set-input-focus (window-frame win))
      (when (and (buffer-live-p orig-buf)
                 (not (eq (window-buffer win) orig-buf)))
        (set-window-buffer win orig-buf)))))

(defun agent-shell-hq-peek-new-shell ()
  "Launch a new agent-shell in the current project and dismiss peek."
  (interactive)
  (let ((win agent-shell-hq-peek--origin-window))
    (agent-shell-hq-peek-quit)
    (when (window-live-p win)
      (select-window win)
      (agent-shell-new-shell))))

;;;; Entry point

;;;###autoload
(defun agent-shell-hq-peek ()
  "Show a posframe listing all agent-shell buffers grouped by project.

n/p navigates, RET selects, g/q/C-g quits."
  (interactive)
  (let* ((origin-win   (selected-window))
         (groups       (agent-shell-hq-peek--grouped-buffers)))
    (unless groups
      (user-error "No agent-shell buffers found"))
    (setq agent-shell-hq-peek--origin-window origin-win
          agent-shell-hq-peek--origin-buffer  (window-buffer origin-win)
          agent-shell-hq-peek--current-idx   0)
    (agent-shell-hq-peek--render groups)
    (agent-shell-hq-peek--highlight-line 0)
    (with-current-buffer agent-shell-hq-peek--buffer-name
      (use-local-map agent-shell-hq-peek-map))
    (setq agent-shell-hq-peek--saved-terminal-map overriding-terminal-local-map
          overriding-terminal-local-map agent-shell-hq-peek--quit-override-map)
    (posframe-show agent-shell-hq-peek--buffer-name
                   :poshandler            #'agent-shell-hq-peek--poshandler
                   :width                 agent-shell-hq-peek-width
                   :max-height            agent-shell-hq-peek-height
                   :internal-border-width 4
                   :border-color          (face-foreground 'shadow nil t)
                   :accept-focus          t
                   :override-parameters   agent-shell-hq-peek-parameters)
    (agent-shell-hq-peek--preview-current)
    (let ((pf-frame (buffer-local-value 'posframe--frame
                                        (get-buffer agent-shell-hq-peek--buffer-name))))
      (when (framep pf-frame)
        (select-frame-set-input-focus pf-frame)
        (select-window (frame-selected-window pf-frame) t)))))

(provide 'agent-shell-hq-peek)
;;; agent-shell-hq-peek.el ends here
