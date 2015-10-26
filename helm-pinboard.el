;;; helm-pinboard.el --- Helm extension for Pinboard bookmarks  -*- lexical-binding: t; -*-

;; Copyright (C) 2008 - 2009 Thierry Volpiatto <thierry.volpiatto@gmail.com>
;;               2009 - 2015 Joe Bloggs <vapniks@yahoo.com>
;;               2015 Puneeth Chaganti <punchagan@muse-amuse.in>

;; This is a fork of helm-delicious.el written by Thierry Volpiatto.

;; Author: Puneeth Chaganti <punchagan@muse-amuse.in>
;; Keywords: tools, comm, convenience
;; URL: https://github.com/punchagan/helm-pinboard
;; Version: 1.4
;; Created: 2015-10-24
;; Package-Requires: ((helm "1.4.0") (cl-lib "0.3"))

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;; Helm interface for Pinboard bookmarks.

;; Pinboard API is more or less compatible with Delicious API and this is fork
;; of helm-delicious.el. The code should probably work with delicious by just
;; changing the API base url, though this is untested.

;; This code use `curl' for asynchronous requests to the server.

;; Setup:

;; Add to .emacs:
;; (require 'helm-pinboard)

;; After subscribing to http://pinboard.in/ setup your login and password:

;; You can set it up in your init file by setting `helm-pinboard-user' and
;; `helm-pinboard-password'.

;; or save it to your .authinfo file by adding a line like this:

;; machine api.del.icio.us:443 port https login xxxxx password xxxxx

;; and add to you init file (.emacs):

;; (require 'auth-source)

;; (if (file-exists-p "~/.authinfo.gpg")
;;     (setq auth-sources '((:source "~/.authinfo.gpg" :host t :protocol t)))
;;     (setq auth-sources '((:source "~/.authinfo" :host t :protocol t))))

;; DON'T CALL `helm-pinboard-authentify', this will set your login and password
;; globally.

;; Use:

;; M-x helm-pinboard
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Code:

(require 'cl)
(require 'helm)
(require 'xml)

;; User variables
(defvar helm-pinboard-base-url
  "https://api.pinboard.in/v1"
  "Base url for the API end points.")

(defvar helm-pinboard-endpoint-all-posts
  "/posts/all?"
  "End point for retrieving all bookmarks")

(defvar helm-pinboard-endpoint-delete
  "/posts/delete?&url=%s"
  "Url for deleting a bookmark")

(defvar helm-pinboard-endpoint-add
  "/posts/add?&url=%s&description=%s&tags=%s"
  "End-point for adding a bookmark.")

(defvar helm-pinboard-fetch-page-title t
  "Page title for bookmark is fetched from page, if set.")

(defvar helm-pinboard-url-methods
  '((elfeed-show-mode . (lambda ()
                          (save-excursion
                            (goto-char (point-min))
                            (save-match-data
                              (re-search-forward "^Title: \\(.*\\)$")
                              (match-string 1)))))))

(defcustom helm-c-pinboard-cache-file "~/.pinboard.cache"
  "The location of the cache file for `helm-pinboard'."
  :group 'helm
  :type 'file)

(defvar helm-pinboard-user nil
  "Your Pinboard login")
(defvar helm-pinboard-password nil
  "Your Pinboard password")

;; Faces
(defface helm-pinboard-tag-face '((t (:foreground "VioletRed4" :weight bold)))
         "Face for w3m bookmarks" :group 'helm)

(defface helm-w3m-bookmarks-face '((t (:foreground "cyan1" :underline t)))
         "Face for w3m bookmarks" :group 'helm)

;; Internal variables (don't modify)
(defvar helm-c-pinboard-cache nil)
(defvar helm-pinboard-last-candidate-to-deletion nil)
(defvar helm-pinboard-last-pattern nil)

(defvar helm-c-source-pinboard-tv
  '((name . "pinboard.in")
    (init . (lambda ()
              (unless helm-c-pinboard-cache
                (setq helm-c-pinboard-cache
                      (helm-set-up-pinboard-bookmarks-alist)))))
    (candidates . (lambda () (mapcar #'car helm-c-pinboard-cache)))
    (candidate-transformer helm-c-highlight-pinboard-bookmarks)
    (action . (("Browse Url default" . (lambda (elm)
                                         (helm-c-pinboard-browse-bookmark elm)
                                         (setq helm-pinboard-last-pattern helm-pattern)))
               ("Browse Url Firefox" . (lambda (candidate)
                                         (helm-c-pinboard-browse-bookmark candidate 'firefox)))
               ("Browse Url Chromium" . (lambda (candidate)
                                          (helm-c-pinboard-browse-bookmark candidate 'chromium)))
               ("Browse Url w3m" . (lambda (candidate)
                                     (helm-c-pinboard-browse-bookmark candidate 'w3m)
                                     (setq helm-pinboard-last-pattern helm-pattern)))
               ("Delete bookmark" . (lambda (elm)
                                      (helm-c-pinboard-delete-bookmark elm)))
               ("Copy Url" . (lambda (elm)
                               (kill-new (helm-c-pinboard-bookmarks-get-value elm))))
               ("Update Tags" . (lambda (elm)
                                  (helm-c-pinboard-update-tags elm)))
               ("Update All" . (lambda (elm)
                                 (message "Wait Loading bookmarks from Pinboard...")
                                 (helm-pinboard-update-async)))))))


(defvar helm-source-is-pinboard nil)
(defadvice helm-select-action (before remember-helm-pattern () activate)
  "Remember helm-pattern when opening helm-action-buffer"
  (when helm-source-is-pinboard
    (setq helm-pinboard-last-pattern helm-pattern)))

(defun helm-pinboard-remove-flag ()
  (setq helm-source-is-pinboard nil))

(add-hook 'helm-cleanup-hook 'helm-pinboard-remove-flag)

(defun helm-pinboard-authentify ()
  "Authentify user from .authinfo file.
You have to setup correctly `auth-sources' to make this function
finding the path of your .authinfo file that is normally ~/.authinfo."
  (let ((helm-pinboard-auth
         (auth-source-user-or-password  '("login" "password")
                                        "api.pinboard.in:443"
                                        "https")))
    (when helm-pinboard-auth
      (setq helm-pinboard-user (car helm-pinboard-auth)
            helm-pinboard-password (cadr helm-pinboard-auth))
      nil)))

;;;###autoload
(defun helm-pinboard-update-async (&optional sentinel)
  "Get the pinboard bookmarks asynchronously

Uses external program curl."
  (interactive)
  (let ((fmd-command "curl -s -o %s -u %s:%s %s"))
    (unless (and helm-pinboard-user helm-pinboard-password)
      (helm-pinboard-authentify))
    (message "Syncing with Pinboard in Progress...")
    (start-process-shell-command
     "curl-retrieve-pinboard" nil
     (format fmd-command
             helm-c-pinboard-cache-file
             helm-pinboard-user
             helm-pinboard-password
             (concat helm-pinboard-base-url helm-pinboard-endpoint-all-posts)))
    (set-process-sentinel
     (get-process "curl-retrieve-pinboard")
     (if sentinel
         sentinel
       #'(lambda (process event)
           (if (string= event "finished\n")
               (message "Syncing with Pinboard...Done.")
             (message "Failed to synchronize with Pinboard."))
           (setq helm-c-pinboard-cache nil))))))


(defun helm-c-pinboard-delete-bookmark (candidate &optional url-value-fn sentinel)
  "Delete pinboard bookmark on the pinboard side"
  (let* ((url     (if url-value-fn
                      (funcall url-value-fn candidate)
                    (helm-c-pinboard-bookmarks-get-value candidate)))
         (url-api (concat helm-pinboard-base-url
                          (format helm-pinboard-endpoint-delete url)))
         helm-pinboard-user
         helm-pinboard-password
         auth)
    (unless (and helm-pinboard-user helm-pinboard-password)
      (helm-pinboard-authentify))
    (setq auth (concat helm-pinboard-user ":" helm-pinboard-password))
    (message "Wait sending request to pinboard...")
    (setq helm-pinboard-last-candidate-to-deletion candidate)
    (apply #'start-process "curl-pinboard-delete" "*pinboard-delete*" "curl"
           (list "-u"
                 auth
                 url-api))
    (set-process-sentinel (get-process "curl-pinboard-delete")
                          (or sentinel 'helm-pinboard-delete-sentinel))))


(defun helm-pinboard-delete-sentinel (process event)
  "Sentinel func for `helm-c-pinboard-delete-bookmark'"
  (message "%s process is %s" process event)
  (sit-for 1)
  (with-current-buffer "*pinboard-delete*"
    (goto-char (point-min))
    (if (re-search-forward "<result code=\"done\" />" nil t)
        (progn
          (helm-c-pinboard-delete-bookmark-local
           helm-pinboard-last-candidate-to-deletion)
          (setq helm-c-pinboard-cache nil)
          (message "Ok %s have been deleted with success"
                   (substring-no-properties
                    helm-pinboard-last-candidate-to-deletion)))
      (message "Fail to delete %s"
               (substring-no-properties
                helm-pinboard-last-candidate-to-deletion)))
    (setq helm-pinboard-last-candidate-to-deletion nil)))


(defun helm-c-pinboard-delete-bookmark-local (candidate)
  "Delete pinboard bookmark on the local side"
  (let ((cand (when (string-match "\\[.*\\]" candidate)
                (substring candidate (1+ (match-end 0))))))
    (with-current-buffer (find-file-noselect helm-c-pinboard-cache-file)
      (goto-char (point-min))
      (when (re-search-forward cand (point-max) t)
        (beginning-of-line)
        (delete-region (point) (point-at-eol))
        (delete-blank-lines))
      (save-buffer)
      (kill-buffer (current-buffer)))))

(defun helm-set-up-pinboard-bookmarks-alist ()
  "Setup an alist of all pinboard bookmarks from xml file"
  (let ((gen-alist ())
        (tag-list ())
        (tag-len 0))
    (unless (file-exists-p helm-c-pinboard-cache-file)
      (message "Wait Loading bookmarks from Pinboard...")
      (helm-pinboard-update-async))
    (setq tag-list (helm-pinboard-get-all-tags-from-cache))
    (loop for i in tag-list
          for len = (length i)
          when (> len tag-len) do (setq tag-len len))
    (with-temp-buffer
      (insert-file-contents helm-c-pinboard-cache-file)
      (setq gen-alist (xml-get-children
                       (car (xml-parse-region (point-min)
                                              (point-max)))
                       'post)))
    (loop for i in gen-alist
          for tag = (xml-get-attribute i 'tag)
          for desc = (xml-get-attribute i 'description)
          for url = (xml-get-attribute i 'href)
          for interval = (- tag-len (length tag))
          collect (cons (concat "[" tag "] " desc) url))))

;;;###autoload
(defun helm-pinboard-add-bookmark (url &optional description tags toread)
  "Add a bookmark with the given url."
  (interactive (let ((url (or (thing-at-point-url-at-point)
                              (get-text-property (point) 'shr-url))))
                 (list
                  (read-from-minibuffer "Url: " url)
                  (read-from-minibuffer "Description: "
                                        (helm-pinboard--get-title url))
                  (completing-read-multiple "Tags: "
                                            (helm-pinboard-get-all-tags-from-cache))
                  (y-or-n-p "Save as toread? "))))
  (when (listp tags)
    (setq tags (mapconcat 'identity tags "+")))
  (let* ((description
          (replace-regexp-in-string " " "+" description))
         (url-api (concat helm-pinboard-base-url
                          (format helm-pinboard-endpoint-add url description tags)))
         helm-pinboard-user
         helm-pinboard-password
         auth)
    (when toread (setq url-api (concat url-api "&toread=yes")))
    (unless (and helm-pinboard-user helm-pinboard-password)
      (helm-pinboard-authentify))
    (setq auth (concat helm-pinboard-user ":" helm-pinboard-password))
    (with-temp-buffer
      (apply #'call-process "curl" nil t nil
             `("-u"
               ,auth
               ,url-api))
      (buffer-string)
      (goto-char (point-min))
      (if (re-search-forward "<result code=\"done\" />" nil t)
          (unwind-protect
              (message "%s added to pinboard" description)
            (helm-pinboard-update-async))
        (message "Failed to add bookmark to pinboard")))))

(defun helm-pinboard--get-title (url)
  "Get title/description for a url.

Buffer specific methods can be defined by adding to the alist
`helm-pinboard-url-methods'. For buffers that don't have custom
methods, the title is fetched by accessing the url, if
`helm-pinboard-fetch-page-title' is set."

  (let ((method (cdr (assoc major-mode helm-pinboard-url-methods))))
    (if method
        (funcall method)
      (if helm-pinboard-fetch-page-title
          (let ((url-buffer (url-retrieve-synchronously url)))
            (if url-buffer
                (with-current-buffer url-buffer
                  (goto-char (point-min))
                  (save-match-data
                    (re-search-forward "<title>\\(.*\\)</title>" nil t 1)
                    (match-string-no-properties 1)))
              (buffer-name (current-buffer))))
        (buffer-name (current-buffer))))))

(defun helm-c-pinboard-update-tags (candidate)
  "Update tags for a given bookmark."
  (let* ((candidate-re "^\\[\\(.*?\\)\\]\s*\\(.*\\)$")
         (url (helm-c-pinboard-bookmarks-get-value candidate))
         (old-tags (replace-regexp-in-string candidate-re "\\1" candidate))
         (description (replace-regexp-in-string candidate-re "\\2" candidate))
         (tags (completing-read-multiple "Tags: "
                                         (helm-pinboard-get-all-tags-from-cache)
                                         nil
                                         nil
                                         (replace-regexp-in-string " " "," old-tags))))
    (helm-pinboard-add-bookmark url description tags)))

(defun helm-pinboard-get-all-tags-from-cache ()
  "Return a list of all tags ever used by you.

 Used for completion on tags when adding bookmarks."
  (with-current-buffer (find-file-noselect helm-c-pinboard-cache-file)
    (goto-char (point-min))
    (let* ((all (car (xml-parse-region (point-min) (point-max))))
           (posts (xml-get-children all 'post))
           tag-list)
      (dolist (post posts)
        (let ((tags (xml-get-attribute post 'tag)))
          (dolist (tag (split-string tags " "))
            (unless (member tag tag-list) (push tag tag-list)))))
      (kill-buffer)
      tag-list)))

(defun helm-c-pinboard-bookmarks-get-value (elm)
  "Get the value of key elm from alist"
  (replace-regexp-in-string
   "\"" "" (cdr (assoc elm helm-c-pinboard-cache))))

(defun helm-c-pinboard-browse-bookmark (x &optional browser new-tab)
  "Action function for helm-pinboard"
  (let* ((fn (case browser
               (firefox 'browse-url-firefox)
               (chromium 'browse-url-chromium)
               (w3m 'w3m-browse-url)
               (t 'browse-url)))
         (arg (and (eq fn 'w3m-browse-url) new-tab)))
    (dolist (elm (helm-marked-candidates))
      (funcall fn (helm-c-pinboard-bookmarks-get-value elm) arg))))

(defun helm-c-highlight-pinboard-bookmarks (books)
  "Highlight all Pinboard bookmarks"
  (let (tag rest-text)
    (loop for i in books
          when (string-match "\\[.*\\] *" i)
          collect (concat (propertize (match-string 0 i)
                                      'face 'helm-pinboard-tag-face)
                          (propertize (substring i (match-end 0))
                                      'face 'helm-w3m-bookmarks-face
                                      'help-echo (helm-c-pinboard-bookmarks-get-value i))))))

;;;###autoload
(defun helm-pinboard ()
  "Start helm-pinboard outside of main helm"
  (interactive)
  (setq helm-source-is-pinboard t)
  (let ((rem-pattern (if helm-pinboard-last-pattern
                         helm-pinboard-last-pattern)))
    (helm 'helm-c-source-pinboard-tv
          rem-pattern nil nil nil "*Helm Pinboard*")))

(provide 'helm-pinboard)

;;; helm-pinboard.el ends here
