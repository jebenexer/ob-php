;;; ob-php.el --- org-babel functions for php evaluation

;; Copyright (C) steckerhalter

;; Author: steckerhalter
;; Keywords: literate programming, reproducible research, php
;; Homepage: https://github.com/steckerhalter/ob-php

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Org-Babel support for evaluating php source code.

;;; Requirements:

;; php command line executable

;;; Code:
(require 'ob)
;(require 'ob-eval)
(eval-when-compile (require 'cl))

(add-to-list 'org-babel-tangle-lang-exts '("php"))

(defvar org-babel-default-header-args:php '())

(defvar org-babel-php-command "php"
  "Name of command to use for executing ruby code.")

(defconst org-babel-header-args:php
  '((dbhost	       . :any)
    (dbport	       . :any)
    (dbuser	       . :any)
    (dbpassword	       . :any)
    (database	       . :any)
    (auto_prepend_file . :any))
  "PHP/SQL-specific header arguments.")

(defun org-babel-execute:php (body params)
  "Execute a block of PHP code with Babel.
This function is called by `org-babel-execute-src-block'."
  (let* ((session (org-babel-php-initiate-session (cdr (assoc :session params))))
         (result-params (cdr (assoc :result-params params)))
         (result-type (cdr (assoc :result-type params)))
         (full-body (org-babel-expand-body:generic
                     body params
                     (append
                      (org-babel-variable-assignments:php params)
                      (org-babel-php-prepend params)
                      (org-babel-ini-assignments:php params)
                      )))
         (result (org-babel-php-evaluate session full-body result-type result-params)))
    (org-babel-reassemble-table
     result
     (org-babel-pick-name (cdr (assoc :colname-names params))
                          (cdr (assoc :colnames params)))
     (org-babel-pick-name (cdr (assoc :rowname-names params))
                          (cdr (assoc :rownames params))))))

(defun org-babel-php-prepend (params)
  "Include prepended file"
  (list (if (cdr (assoc :auto_prepend_file params))
        (format "include '%s';"
                (cdr (assoc :auto_prepend_file params))))))

(defun org-babel-ini-assignments:php (params)
  "Return PHP ini Assignments"
  (mapcar
   (lambda (pair)
     (if
         (cdr (assoc (cdr pair) params))
         (format "ini_set('%s', '%s');"
                 (car pair)
                 (cdr (assoc (cdr pair) params)))
       ))
   '(("mysql.default_host"     . :dbhost)
     ("mysql.default_user"     . :dbuser)
     ("mysql.default_password" . :dbpassword)
     ("mysql.default_port"     . :dbport)
     ("mysql.default_database" . :database))))

(defun org-babel-variable-assignments:php (params)
  "Return list of PHP statements assigning the block's variables."
  (mapcar
   (lambda (pair)
     (format "$%s = %s;"
             (car pair)
             (org-babel-php-var-to-php (cdr pair))))
   (mapcar #'cdr (org-babel-get-header params :var))))

(defun org-babel-php-var-to-php (var)
  "Convert VAR into a php variable.
Convert an elisp value into a string of PHP source code
specifying a variable of the same value."
  (if (listp var)
      (concat "[" (mapconcat #'org-babel-php-var-to-php var ", ") "]")
    (format "%S" var)))

(defun org-babel-php-table-or-string (results)
  "Convert RESULTS into an appropriate elisp value.
If RESULTS look like a table, then convert them into an
Emacs-lisp table, otherwise return the results as a string."
  (org-babel-script-escape results))

(defun org-babel-php-initiate-session (&optional session params)
  "Initiate a PHP session.
If there is not a current inferior-process-buffer in SESSION
then create one.  Return the initialized session."
  (unless (string= session "none")
    (require 'php-boris)
    (let ((session-buffer
           (save-window-excursion
             (php-boris)
             (add-hook 'comint-preoutput-filter-functions
                       'org-babel-php-comint-preoutput-filter nil t)
             (current-buffer))))
      (if (org-babel-comint-buffer-livep session-buffer)
          (progn (sit-for .2 t) session-buffer)
        (error "Could not create session with php-boris")))))

(defvar org-babel-php-comint-preoutput-var nil)

(defun org-babel-php-comint-preoutput-filter (string)
  "REPL output STRING is run through this function.
We filter out all the return values and the boris> prompts so
that only output remains.  An empty string is passed to the boris
repl so that we don't clutter it."
  (setq org-babel-php-comint-preoutput-var
        (org-babel-trim
         (mapconcat ; put the string together again
          (lambda (l)
            (replace-regexp-in-string "\\(^\\|\n\\) → .*?\\($\\|\n\\)" "" l))
          (split-string ; split the rest around the prompt
           (replace-regexp-in-string
            "\r" ""
            (ansi-color-filter-apply ; filter ansi colors
             (replace-regexp-in-string
              (concat "^\\(" org-babel-php-body "\\)\\'") ; remove echoed input
              ""
              string nil nil 1)))
           "\\[[0-9]+\\] boris> ")
          "")))
  string)

(defvar org-babel-php-wrapper-method
  "
<?php
$results = eval(<<<'ORGMODE_EVAL_PHP'
%s
ORGMODE_EVAL_PHP
);
file_put_contents('%s', $results);
")

(defvar org-babel-php-pp-wrapper-method
  "
<?php
ob_start();
var_dump(array(eval(<<<'ORGMODE_EVAL_PHP'
%s
ORGMODE_EVAL_PHP
), print(ob_get_clean()), ob_start())[0]);
file_put_contents('%s', ob_get_clean());
")

(defun org-babel-php-evaluate (session body &optional result-type result-params)
  "Evaluate BODY as PHP code."
    (if session
      (org-babel-php-evaluate-session
       session body result-type result-params)
    (org-babel-php-evaluate-external-process
     body result-type result-params)))

(defun org-babel-php-evaluate-external-process
  (body &optional result-type result-params)
  "Evaluate BODY in external PHP process.
If RESULT-TYPE equals 'output then return standard output as a
string.  If RESULT-TYPE equals 'value then return the value of the
last statement in BODY, as elisp."
  (case result-type
    (output (org-babel-eval org-babel-php-command (concat "<?php\n" body)))
    (value (let ((tmp-file (org-babel-temp-file "php-")))
             (org-babel-eval
              org-babel-php-command
              (format (if (member "pp" result-params)
                          org-babel-php-pp-wrapper-method
                        org-babel-php-wrapper-method)
                      body (org-babel-process-file-name tmp-file 'noquote)))
             ((lambda (raw)
                (if (or (member "code" result-params)
                        (member "pp" result-params))
                    raw
                  (org-babel-php-table-or-string raw)))
              (org-babel-eval-read-file tmp-file))))))

(defun org-babel-php-evaluate-session
  (session body &optional result-type result-params)
  "Pass BODY to the PHP process in SESSION.
If RESULT-TYPE equals 'output then return standard output as a
string.  If RESULT-TYPE equals 'value then return the value of the
last statement in BODY, as elisp."
  (case result-type
    (output
     (setq org-babel-php-body body)
     (let ((buffer (generate-new-buffer " *boris-repl-temp*")) result)
       (comint-redirect-send-command-to-process body buffer session t t)
       (while (not org-babel-php-comint-preoutput-var)
         (sit-for .1 t))
       (kill-buffer buffer)
       (setq result org-babel-php-comint-preoutput-var)
       (setq org-babel-php-comint-preoutput-var nil)
       result
       ))
    (value
     (error "Value support for session not implemented yet"))))

(provide 'ob-php)

;;; ob-php.el ends here
