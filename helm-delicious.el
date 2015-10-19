;;; helm-delicious.el --- helm extensions for delicious bookmarks

;; Filename: helm-delicious.el
;; Description:
;; Author: Thierry Volpiatto <thierry.volpiatto@gmail.com>
;; Maintainer: Joe Bloggs <vapniks@yahoo.com>
;; Copyright (C) 2008, 2009 Thierry Volpiatto, all rights reserved
;; Version: 1.3
;; Last-Updated: 2013-11-11 01:28:00
;; URL: https://github.com/vapniks/helm-delicious
;; Keywords:
;; Compatibility: Gnus Emacs 24.3
;;
;; Features that might be required by this library:
;;
;; `helm' `xml'
;;


;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;  ==========
;;
;; Helm interface for Delicious bookmarks.

;; This code use `curl' for asynchronous requests to the server.

;; You need to install `helm' also.
;; Install:
;; =======
;;
;; Add to .emacs:
;; (require 'helm-delicious)
;;
;; after subscribing to http://delicious.com/
;; Setup your login and delicious password:
;;
;; You can set it up in your init file with
;;
;; `helm-delicious-user' and `helm-delicious-password'
;; (use setq)
;;
;; or better:
;;
;; Add a line like this in your .authinfo file:
;;
;; machine api.del.icio.us:443 port https login xxxxx password xxxxx
;;
;; and add to you init file (.emacs):
;; (require 'auth-source)
;;
;; (if (file-exists-p "~/.authinfo.gpg")
;;     (setq auth-sources '((:source "~/.authinfo.gpg" :host t :protocol t)))
;;     (setq auth-sources '((:source "~/.authinfo" :host t :protocol t))))
;;
;; Warning:
;;
;; DON'T CALL `helm-delicious-authentify', this will set your login and password
;; globally.
;;
;; Use:
;; ===
;;
;; M-x helm-delicious
;; That should create a "~/.delicious-cache" file.
;; (you can set that to another value with `helm-c-delicious-cache-file')
;; You can also add `helm-c-source-delicious-tv' to the `helm-sources'.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Code:

(require 'xml)

;; User variables
(defvar helm-delicious-base-url
  "https://api.pinboard.in/v1"
  "Base url for the API end points.")

(defvar helm-delicious-endpoint-all-posts
  "/posts/all?"
  "End point for retrieving all bookmarks")

(defvar helm-delicious-endpoint-delete
  "/posts/delete?&url=%s"
  "Url for deleting a bookmark")

(defvar helm-delicious-endpoint-add
  "/posts/add?&url=%s&description=%s&tags=%s"
  "End-point for adding a bookmark.")

(defvar helm-delicious-fetch-page-title t
  "Page title for bookmark is fetched from page, if set.")

(defvar helm-delicious-url-methods
  '((elfeed-show-mode . (lambda ()
                          (save-excursion
                            (goto-char (point-min))
                            (save-match-data
                              (re-search-forward "^Title: \\(.*\\)$")
                              (match-string 1)))))))

(defcustom helm-c-delicious-cache-file "~/.delicious.cache"
  "The location of the cache file for `helm-delicious'."
  :group 'helm
  :type 'file)

(defvar helm-delicious-user nil
  "Your Delicious login")
(defvar helm-delicious-password nil
  "Your Delicious password")

;; Faces
(defface helm-delicious-tag-face '((t (:foreground "VioletRed4" :weight bold)))
         "Face for w3m bookmarks" :group 'helm)

(defface helm-w3m-bookmarks-face '((t (:foreground "cyan1" :underline t)))
         "Face for w3m bookmarks" :group 'helm)

;; Internal variables (don't modify)
(defvar helm-c-delicious-cache nil)
(defvar helm-delicious-last-candidate-to-deletion nil)
(defvar helm-delicious-last-pattern nil)

(defvar helm-c-source-delicious-tv
  '((name . "Del.icio.us")
    (init . (lambda ()
              (unless helm-c-delicious-cache
                (setq helm-c-delicious-cache
                      (helm-set-up-delicious-bookmarks-alist)))))
    (candidates . (lambda () (mapcar #'car helm-c-delicious-cache)))
    (candidate-transformer helm-c-highlight-delicious-bookmarks)
    (action . (("Browse Url default" . (lambda (elm)
                                         (helm-c-delicious-browse-bookmark elm)
                                         (setq helm-delicious-last-pattern helm-pattern)))
               ("Browse Url Firefox" . (lambda (candidate)
                                         (helm-c-delicious-browse-bookmark candidate 'firefox)))
               ("Browse Url Chromium" . (lambda (candidate)
                                          (helm-c-delicious-browse-bookmark candidate 'chromium)))
               ("Browse Url w3m" . (lambda (candidate)
                                     (helm-c-delicious-browse-bookmark candidate 'w3m)
                                     (setq helm-delicious-last-pattern helm-pattern)))
               ("Delete bookmark" . (lambda (elm)
                                      (helm-c-delicious-delete-bookmark elm)))
               ("Copy Url" . (lambda (elm)
                               (kill-new (helm-c-delicious-bookmarks-get-value elm))))
               ("Update Tags" . (lambda (elm)
                                  (helm-c-delicious-update-tags elm)))
               ("Update All" . (lambda (elm)
                                 (message "Wait Loading bookmarks from Delicious...")
                                 (helm-delicious-update-async)))))))


;; (helm 'helm-c-source-delicious-tv)

(defvar helm-source-is-delicious nil)
(defadvice helm-select-action (before remember-helm-pattern () activate)
  "Remember helm-pattern when opening helm-action-buffer"
  (when helm-source-is-delicious
    (setq helm-delicious-last-pattern helm-pattern)))

(defun helm-delicious-remove-flag ()
  (setq helm-source-is-delicious nil))

(add-hook 'helm-cleanup-hook 'helm-delicious-remove-flag)

(defun helm-delicious-authentify ()
  "Authentify user from .authinfo file.
You have to setup correctly `auth-sources' to make this function
finding the path of your .authinfo file that is normally ~/.authinfo."
  (let ((helm-delicious-auth
         (auth-source-user-or-password  '("login" "password")
                                        "api.pinboard.in:443"
                                        "https")))
    (when helm-delicious-auth
      (setq helm-delicious-user (car helm-delicious-auth)
            helm-delicious-password (cadr helm-delicious-auth))
      nil)))

;;;###autoload
(defun helm-delicious-update-async (&optional sentinel)
  "Get the delicious bookmarks asynchronously

Uses external program curl."
  (interactive)
  (let ((fmd-command "curl -s -o %s -u %s:%s %s"))
    (unless (and helm-delicious-user helm-delicious-password)
      (helm-delicious-authentify))
    (message "Syncing with Delicious in Progress...")
    (start-process-shell-command
     "curl-retrieve-delicious" nil
     (format fmd-command
             helm-c-delicious-cache-file
             helm-delicious-user
             helm-delicious-password
             (concat helm-delicious-base-url helm-delicious-endpoint-all-posts)))
    (set-process-sentinel
     (get-process "curl-retrieve-delicious")
     (if sentinel
         sentinel
       #'(lambda (process event)
           (if (string= event "finished\n")
               (message "Syncing with Delicious...Done.")
             (message "Failed to synchronize with Delicious."))
           (setq helm-c-delicious-cache nil))))))


(defun helm-c-delicious-delete-bookmark (candidate &optional url-value-fn sentinel)
  "Delete delicious bookmark on the delicious side"
  (let* ((url     (if url-value-fn
                      (funcall url-value-fn candidate)
                    (helm-c-delicious-bookmarks-get-value candidate)))
         (url-api (concat helm-delicious-base-url
                          (format helm-delicious-endpoint-delete url)))
         helm-delicious-user
         helm-delicious-password
         auth)
    (unless (and helm-delicious-user helm-delicious-password)
      (helm-delicious-authentify))
    (setq auth (concat helm-delicious-user ":" helm-delicious-password))
    (message "Wait sending request to delicious...")
    (setq helm-delicious-last-candidate-to-deletion candidate)
    (apply #'start-process "curl-delicious-delete" "*delicious-delete*" "curl"
           (list "-u"
                 auth
                 url-api))
    (set-process-sentinel (get-process "curl-delicious-delete")
                          (or sentinel 'helm-delicious-delete-sentinel))))


(defun helm-delicious-delete-sentinel (process event)
  "Sentinel func for `helm-c-delicious-delete-bookmark'"
  (message "%s process is %s" process event)
  (sit-for 1)
  (with-current-buffer "*delicious-delete*"
    (goto-char (point-min))
    (if (re-search-forward "<result code=\"done\" />" nil t)
        (progn
          (helm-c-delicious-delete-bookmark-local
           helm-delicious-last-candidate-to-deletion)
          (setq helm-c-delicious-cache nil)
          (message "Ok %s have been deleted with success"
                   (substring-no-properties
                    helm-delicious-last-candidate-to-deletion)))
      (message "Fail to delete %s"
               (substring-no-properties
                helm-delicious-last-candidate-to-deletion)))
    (setq helm-delicious-last-candidate-to-deletion nil)))


(defun helm-c-delicious-delete-bookmark-local (candidate)
  "Delete delicious bookmark on the local side"
  (let ((cand (when (string-match "\\[.*\\]" candidate)
                (substring candidate (1+ (match-end 0))))))
    (with-current-buffer (find-file-noselect helm-c-delicious-cache-file)
      (goto-char (point-min))
      (when (re-search-forward cand (point-max) t)
        (beginning-of-line)
        (delete-region (point) (point-at-eol))
        (delete-blank-lines))
      (save-buffer)
      (kill-buffer (current-buffer)))))

(defun helm-set-up-delicious-bookmarks-alist ()
  "Setup an alist of all delicious bookmarks from xml file"
  (let ((gen-alist ())
        (tag-list ())
        (tag-len 0))
    (unless (file-exists-p helm-c-delicious-cache-file)
      (message "Wait Loading bookmarks from Delicious...")
      (helm-delicious-update-async))
    (setq tag-list (helm-delicious-get-all-tags-from-cache))
    (loop for i in tag-list
          for len = (length i)
          when (> len tag-len) do (setq tag-len len))
    (with-temp-buffer
      (insert-file-contents helm-c-delicious-cache-file)
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
(defun helm-delicious-add-bookmark (url &optional description tags toread)
  "Add a bookmark with the given url."
  (interactive (let ((url (or (thing-at-point-url-at-point)
                              (get-text-property (point) 'shr-url))))
                 (list
                  (read-from-minibuffer "Url: " url)
                  (read-from-minibuffer "Description: "
                                        (helm-delicious--get-title url))
                  (completing-read-multiple "Tags: "
                                            (helm-delicious-get-all-tags-from-cache))
                  (y-or-n-p "Save as toread? "))))
  (when (listp tags)
    (setq tags (mapconcat 'identity tags "+")))
  (let* ((description
          (replace-regexp-in-string " " "+" description))
         (url-api (concat helm-delicious-base-url
                          (format helm-delicious-endpoint-add url description tags)))
         helm-delicious-user
         helm-delicious-password
         auth)
    (when toread (setq url-api (concat url-api "&toread=yes")))
    (unless (and helm-delicious-user helm-delicious-password)
      (helm-delicious-authentify))
    (setq auth (concat helm-delicious-user ":" helm-delicious-password))
    (with-temp-buffer
      (apply #'call-process "curl" nil t nil
             `("-u"
               ,auth
               ,url-api))
      (buffer-string)
      (goto-char (point-min))
      (if (re-search-forward "<result code=\"done\" />" nil t)
          (unwind-protect
              (message "%s added to delicious" description)
            (helm-delicious-update-async))
        (message "Failed to add bookmark to delicious")))))

(defun helm-delicious--get-title (url)
  "Get title/description for a url.

Buffer specific methods can be defined by adding to the alist
`helm-delicious-url-methods'. For buffers that don't have custom
methods, the title is fetched by accessing the url, if
`helm-delicious-fetch-page-title' is set."

  (let ((method (cdr (assoc major-mode helm-delicious-url-methods))))
    (if method
        (funcall method)
      (if helm-delicious-fetch-page-title
          (let ((url-buffer (url-retrieve-synchronously url)))
            (if url-buffer
                (with-current-buffer url-buffer
                  (goto-char (point-min))
                  (save-match-data
                    (re-search-forward "<title>\\(.*\\)</title>" nil t 1)
                    (match-string-no-properties 1)))
              (buffer-name (current-buffer))))
        (buffer-name (current-buffer))))))

(defun helm-c-delicious-update-tags (candidate)
  "Update tags for a given bookmark."
  (let* ((candidate-re "^\\[\\(.*?\\)\\]\s*\\(.*\\)$")
         (url (helm-c-delicious-bookmarks-get-value candidate))
         (old-tags (replace-regexp-in-string candidate-re "\\1" candidate))
         (description (replace-regexp-in-string candidate-re "\\2" candidate))
         (tags (completing-read-multiple "Tags: "
                                         (helm-delicious-get-all-tags-from-cache)
                                         nil
                                         nil
                                         (replace-regexp-in-string " " "," old-tags))))
    (helm-delicious-add-bookmark url description tags)))

(defun helm-delicious-get-all-tags-from-cache ()
  "Return a list of all tags ever used by you.

 Used for completion on tags when adding bookmarks."
  (with-current-buffer (find-file-noselect helm-c-delicious-cache-file)
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

(defun helm-c-delicious-bookmarks-get-value (elm)
  "Get the value of key elm from alist"
  (replace-regexp-in-string
   "\"" "" (cdr (assoc elm helm-c-delicious-cache))))

(defun helm-c-delicious-browse-bookmark (x &optional browser new-tab)
  "Action function for helm-delicious"
  (let* ((fn (case browser
               (firefox 'browse-url-firefox)
               (chromium 'browse-url-chromium)
               (w3m 'w3m-browse-url)
               (t 'browse-url)))
         (arg (and (eq fn 'w3m-browse-url) new-tab)))
    (dolist (elm (helm-marked-candidates))
      (funcall fn (helm-c-delicious-bookmarks-get-value elm) arg))))

(defun helm-c-highlight-delicious-bookmarks (books)
  "Highlight all Delicious bookmarks"
  (let (tag rest-text)
    (loop for i in books
          when (string-match "\\[.*\\] *" i)
          collect (concat (propertize (match-string 0 i)
                                      'face 'helm-delicious-tag-face)
                          (propertize (substring i (match-end 0))
                                      'face 'helm-w3m-bookmarks-face
                                      'help-echo (helm-c-delicious-bookmarks-get-value i))))))

;;;###autoload
(defun helm-delicious ()
  "Start helm-delicious outside of main helm"
  (interactive)
  (setq helm-source-is-delicious t)
  (let ((rem-pattern (if helm-delicious-last-pattern
                         helm-delicious-last-pattern)))
    (helm 'helm-c-source-delicious-tv
          rem-pattern nil nil nil "*Helm Delicious*")))

(provide 'helm-delicious)

;;; helm-delicious.el ends here
