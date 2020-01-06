;;; racket-check-syntax.el -*- lexical-binding: t -*-

;; Copyright (c) 2013-2020 by Greg Hendershott.
;; Portions Copyright (C) 1985-1986, 1999-2013 Free Software Foundation, Inc.

;; Author: Greg Hendershott
;; URL: https://github.com/greghendershott/racket-mode

;; License:
;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version. This is distributed in the hope that it will be
;; useful, but without any warranty; without even the implied warranty
;; of merchantability or fitness for a particular purpose. See the GNU
;; General Public License for more details. See
;; http://www.gnu.org/licenses/ for details.

;;; The general approach here:
;;;
;;; - Add text properties with information supplied by the
;;;   drracket/check-syntax module.
;;;
;;; - Refresh in an after-change hook, plus a short idle-timer delay.
;;;
;;; - Point motion hooks add/remove temporarly overlays to highlight
;;;   defs and uses. (We can't draw GUI arrows as in Dr Racket.)

(require 'racket-repl)
(require 'racket-edit)

(defconst racket--check-syntax-overlay-name 'racket-check-syntax-overlay)

(defun racket--check-syntax-overlay-p (o)
  (eq (overlay-get o 'name)
      racket--check-syntax-overlay-name))

(defun racket--highlight (beg end defp &optional after-str)
  (unless (cl-some #'racket--check-syntax-overlay-p
                   (overlays-in beg end))
    (let ((o (make-overlay beg end)))
      (overlay-put o 'name racket--check-syntax-overlay-name)
      (overlay-put o 'priority 100)
      (overlay-put o 'face (if defp
                               racket-check-syntax-def-face
                             racket-check-syntax-use-face))
      (when after-str
        (overlay-put o 'after-string
                     (propertize after-str
                                 'face racket-check-syntax-info-face))))))

(defun racket--unhighlight-all ()
  (remove-overlays (point-min) (point-max) racket--check-syntax-overlay-name))

(defun racket--non-empty-string-p (v)
  (and (stringp v)
       (not (string-match-p "\\`[ \t\n\r]*\\'" v)))) ;`string-blank-p'

(defun racket--point-entered (_old new)
  (let ((help-echo (pcase (get-text-property new 'help-echo)
                     ((and s (pred racket--non-empty-string-p)) s))))
    (when help-echo
      (message "%s" help-echo))
    (pcase (get-text-property new 'racket-check-syntax-def)
      ((and uses `((,beg ,_end) . ,_))
       (pcase (get-text-property beg 'racket-check-syntax-use)
         (`(,beg ,end) (racket--highlight beg end t
                                          nil ;help-echo
                                          )))
       (dolist (use uses)
         (pcase use (`(,beg ,end) (racket--highlight beg end nil))))))
    (pcase (get-text-property new 'racket-check-syntax-use)
      (`(,beg ,end)
       (racket--highlight beg end t)
       (dolist (use (get-text-property beg 'racket-check-syntax-def))
         (pcase use (`(,beg ,end) (racket--highlight
                                   beg end nil
                                   nil ;(and (<= beg new) (< new end) help-echo)
                                   ))))))))

(defun racket--point-left (_old _new)
  (racket--unhighlight-all))

(defun racket-check-syntax-visit-definition ()
  "When point is on a use, go to its definition.

If check-syntax says the definition is not imported, go there.
This handles bindings in the current source file -- even bindings
in internal definition contexts, and even those that shadow other
bindings.

Otherwise defer to `racket-visit-definition'."
  (interactive)
  (pcase (get-text-property (point) 'racket-check-syntax-use)
    (`(,beg ,_end)
     (if (racket--check-syntax-use/def-at-point-is-import-p)
         (racket-visit-definition)
       (racket--push-loc)
       (goto-char beg)))
    (_ (racket-visit-definition))))

(defun racket--check-syntax-use/def-at-point-is-import-p ()
  (not (and (racket--check-syntax-call-with-uses/defs-at-point
             (lambda (&rest _) t)))))

(defun racket-check-syntax--forward-use (amt)
  "When point is on a use, go AMT uses forward. AMT may be negative.

Moving before/after the first/last use wraps around.

If point is instead on a definition, then go to its first use."
  (pcase (get-text-property (point) 'racket-check-syntax-use)
    (`(,beg ,_end)
     (pcase (get-text-property beg 'racket-check-syntax-def)
       (uses (let* ((pt (point))
                    (ix-this (cl-loop for ix from 0 to (1- (length uses))
                                      for use = (nth ix uses)
                                      when (and (<= (car use) pt) (< pt (cadr use)))
                                      return ix))
                    (ix-next (+ ix-this amt))
                    (ix-next (if (> amt 0)
                                 (if (>= ix-next (length uses)) 0 ix-next)
                               (if (< ix-next 0) (1- (length uses)) ix-next)))
                    (next (nth ix-next uses)))
               (goto-char (car next))))))
    (_ (pcase (get-text-property (point) 'racket-check-syntax-def)
         (`((,beg ,_end) . ,_) (goto-char beg))))))

(defun racket-check-syntax-next-use ()
  "When point is on a use, go to the next, sibling use."
  (interactive)
  (racket-check-syntax--forward-use 1))

(defun racket-check-syntax-prev-use ()
  "When point is on a use, go to the previous, sibling use."
  (interactive)
  (racket-check-syntax--forward-use -1))

(defun racket--check-syntax-call-with-uses/defs-at-point (proc)
  "If point on a def or use, call PROC with useful information."
  ;; If we're on a def, get its uses. If we're on a use, get its def.
  (let* ((pt (point))
         (uses (get-text-property pt 'racket-check-syntax-def))
         (def  (get-text-property pt 'racket-check-syntax-use)))
    ;; If we got one, get the other.
    (when (or uses def)
      (let* ((uses (or uses (get-text-property (car def)   'racket-check-syntax-def)))
             (def  (or def  (get-text-property (caar uses) 'racket-check-syntax-use)))
             (locs (cons def uses))
             (strs (mapcar (lambda (loc)
                             (apply #'buffer-substring-no-properties loc))
                           locs)))
        ;; Proceed only if all the strings are the same. (They won't
        ;; be for e.g. import bindings.)
        (when (cl-every (lambda (s) (equal (car strs) s))
                        (cdr strs))
          (funcall proc uses def locs strs))))))

(defun racket-check-syntax-rename ()
  "Rename a definition and its uses in the current file."
  (interactive)
  (racket--check-syntax-call-with-uses/defs-at-point
   (lambda (_uses _def locs strs)
     (let ((new (read-from-minibuffer (format "Rename %s to: " (car strs))))
           (marker-pairs
            (mapcar (lambda (loc)
                      (let ((beg (make-marker))
                            (end (make-marker)))
                        (set-marker beg (nth 0 loc) (current-buffer))
                        (set-marker end (nth 1 loc) (current-buffer))
                        (list beg end)))
                    locs))
           (point-marker (let ((m (make-marker)))
                           (set-marker m (point) (current-buffer)))))
       ;; Don't let our after-change hook run until all changes
       ;; are made, else check-syntax will find a syntax error.
       (let ((inhibit-modification-hooks t))
         (dolist (marker-pair marker-pairs)
           (let ((beg (marker-position (nth 0 marker-pair)))
                 (end (marker-position (nth 1 marker-pair))))
             (delete-region beg end)
             (goto-char beg)
             (insert new))))
       (goto-char (marker-position point-marker))
       (racket--check-syntax-annotate)))))

(defun racket-check-syntax-next-def ()
  (interactive)
  (let ((pos (next-single-property-change (point) 'racket-check-syntax-def)))
    (when pos
      (unless (get-text-property pos 'racket-check-syntax-def)
        (setq pos (next-single-property-change pos 'racket-check-syntax-def)))
      (and pos (goto-char pos)))))

(defun racket-check-syntax-prev-def ()
  (interactive)
  (let ((pos (previous-single-property-change (point) 'racket-check-syntax-def)))
    (when pos
      (unless (get-text-property pos 'racket-check-syntax-def)
        (setq pos (previous-single-property-change pos 'racket-check-syntax-def)))
      (and pos (goto-char pos)))))

(defvar racket-check-syntax-control-c-hash-keymap
  (racket--easy-keymap-define
   '(("j" racket-check-syntax-next-def)
     ("k" racket-check-syntax-prev-def)
     ("n" racket-check-syntax-next-use)
     ("p" racket-check-syntax-prev-use)
     ("." racket-check-syntax-visit-definition)
     ("r" racket-check-syntax-rename))) )

;;;###autoload
(define-minor-mode racket-check-syntax-mode
  "A minor mode that annotates information supplied by drracket/check-syntax.

When point is on a definition or use, related items are
highlighted -- instead of drawing arrows as in Dr Racket -- and
information is displayed in the echo area or a tooltip. You may
also use commands to navigate among a definition and its uses, or
rename all of them.

When you edit the buffer, the position of existing annotations is
adjusted. Annotations for new text are not made until you save
the buffer, at which time the entire buffer is freshly annotated.

\\{racket-check-syntax-mode-map}
"
  :lighter " CheckSyntax"
  :keymap (racket--easy-keymap-define
           `(("C-c #" ,racket-check-syntax-control-c-hash-keymap)
             ("M-."   ,#'racket-check-syntax-visit-definition)))
  (unless (eq major-mode 'racket-mode)
    (setq racket-check-syntax-mode nil)
    (user-error "racket-check-syntax-mode only works with racket-mode buffers"))
  (racket--check-syntax-clear)
  (remove-hook 'after-change-functions
               #'racket--check-syntax-after-change-hook
               t)
  (when racket-check-syntax-mode
    (racket--check-syntax-annotate)
    (add-hook 'after-change-functions
              #'racket--check-syntax-after-change-hook
              t t)))

(defvar racket--check-syntax-after-change-refresh-delay 2
  "How many idle seconds until refreshing check-syntax annotations.")
(defvar-local racket--check-syntax-timer nil)
(defun racket--check-syntax-after-change-hook (_beg _end _len)
  (when (timerp racket--check-syntax-timer)
    (cancel-timer racket--check-syntax-timer))
  (setq racket--check-syntax-timer
        (run-with-idle-timer racket--check-syntax-after-change-refresh-delay
                             nil ;no repeat
                             #'racket--check-syntax-annotate)))

(defun racket--check-syntax-annotate ()
  ;; Use cmd/async-raw to silently ignore error responses such as
  ;; "undefined variable" while the user edits their code.
  (let ((buf (current-buffer)))
    (racket--cmd/async-raw
     `(check-syntax ,(racket--buffer-file-name)
                    ,(buffer-substring-no-properties (point-min) (point-max)))
     (lambda (response)
       (with-current-buffer buf
         (pcase response
           (`(ok ())
            (racket--check-syntax-clear))
           (`(ok ,xs)
            (racket--check-syntax-clear)
            (racket--check-syntax-insert xs))))))))

(defun racket--check-syntax-insert (xs)
  "Insert text properties. Convert integer positions to markers."
  (with-silent-modifications
    (overlay-recenter (point-max)) ;faster
    (dolist (x xs)
      (pcase x
        (`(,`info ,beg ,end ,str)
         (let ((beg (copy-marker beg t))
               (end (copy-marker end t)))
           (put-text-property beg end 'help-echo str)))
        (`(,`def/uses ,def-beg ,def-end ,uses)
         (let ((def-beg (copy-marker def-beg t))
               (def-end (copy-marker def-end t))
               (uses    (mapcar (lambda (xs)
                                  (mapcar (lambda (x)
                                            (copy-marker x t))
                                          xs))
                                uses)))
          (add-text-properties def-beg
                               def-end
                               (list 'racket-check-syntax-def uses
                                     'point-entered #'racket--point-entered
                                     'point-left    #'racket--point-left))
          (dolist (use uses)
            (pcase-let* ((`(,use-beg ,use-end) use))
              (add-text-properties use-beg
                                   use-end
                                   (list 'racket-check-syntax-use (list def-beg
                                                                        def-end)
                                         'point-entered #'racket--point-entered
                                         'point-left    #'racket--point-left))))))))
    ;; Make 'point-entered and 'point-left work in Emacs 25+. Note
    ;; that this is somewhat of a hack -- I spent a lot of time trying
    ;; to Do the Right Thing using the new cursor-sensor-mode, but
    ;; could not get it to work satisfactorily. See:
    ;; http://emacs.stackexchange.com/questions/29813/point-motion-strategy-for-emacs-25-and-older
    (setq-local inhibit-point-motion-hooks nil)))

(defun racket--check-syntax-clear ()
  (with-silent-modifications
    (remove-text-properties (point-min)
                            (point-max)
                            '(help-echo nil
                              racket-check-syntax-def nil
                              racket-check-syntax-use nil
                              point-entered
                              point-left))
    (racket--unhighlight-all)))

(provide 'racket-check-syntax)

;; racket-check-syntax.el ends here