(defpackage #:cl-openid.example-provider
  (:use #:common-lisp #:cl-openid #:puri #:hunchentoot))

(in-package #:cl-openid.example-provider)

(defun html (title body &rest body-args)
  "Simple HTML formatting."
  (format nil "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\"
   \"http://www.w3.org/TR/html4/strict.dtd\">
<html><head><title>~A</title></head>
<body>~?</body></html>"
          title body body-args))

;;; Store handled requests
(defvar *requests* (make-hash-table :test #'equal)
  "Handled requests store.

This hashtable is used to store requests for time of dialogue with
user, between initial checkid_setup request and final decision.")

(defvar *requests-counter* 0
  "Counter for generating unique stored request IDs.")

(defun store-request
    (message &aux (handle (cl-base64:integer-to-base64-string (incf *requests-counter*) :uri t)))
  "Store MESSAGE request in *REQUESTS* under new key, return key."
  (setf (gethash handle *requests*) message)
  handle)

;;; Actual provider class.

;; To customize OP behaviour and use httpd-specific functions, we need
;; to create subclass of provided abstract OPENID-PROVIDER class.
(defclass example-op (openid-provider)
  ((finish-uri :initarg :finish-uri :reader finish-uri
	       :documentation "URI for setup finalization, filled on instance initialization.")))


;; HANDLE-CHECKID-IMMEDIATE method is called on checkid_immediate
;; request.  It should examine the request and message, and return
;; whether to accept or reject the request.  We try to be funny and to
;; avoid complicating the example too much, and accept every second
;; request.
(defvar *checkid-immediate-counter* 0)
(defmethod handle-checkid-immediate ((op example-op) message)
  "Handle checkid_immediate: accept every second request"
  (declare (ignore message))
  (oddp (incf *checkid-immediate-counter*)))

;; Methods below do reply to OpenID endpoint requests.  They should
;; return the same values as HANDLE-OPENID-PROVIDER-REQUEST: reply
;; body and optional HTTP code. If code is a redirect (3xx), body
;; (first returned value) is actually a redirect URI (URI object or
;; string).

;; HANDLE-CHECKID-SETUP method is called on checkid_setup request.  It
;; is supposed to handle dialogue with end-user, and is responsible
;; for storing MESSAGE object for time of the dialogue.
(defmethod handle-checkid-setup
    ((op example-op) message
     &aux (handle (store-request message)))
  "Response for checkid_setup request.

Presents request details and a simple choice consisting of two links
to FINISH-URI with different parameters."
  (values 
   (html "Log in?"
         "<h2>Message:</h2>
<dl>~:{<dt>~A</dt><dd>~A</dd>~}</dl>
<strong><a href=\"~A\">Log in</a> or <a href=\"~A\">cancel</a>?</strong>"
         (mapcar #'(lambda (c)
                     (list (car c) (cdr c)))
                 message)
         (copy-uri (finish-uri op) :query (format nil "handle=~A&allow=1" handle))
         (copy-uri (finish-uri op) :query (format nil "handle=~A&deny=1" handle)))
   200))
  
;; FINISH-CHECKID-SETUP function is called on request to FINISH-URI,
;; by user clicking one of links presented in response from
;; HANDLE-CHECKID-SETUP.  Analyzes request parameters, and returns
;; an relying party URI to redirect the user's browser to 
;; (indirect response). The URI parameters tell the relying party
;; if the authentication was successful or not.
(defun finish-checkid-setup (op &aux
                             (handle (get-parameter "handle"))
                             (message (gethash handle *requests*))) ; Recover stored message
  "Finish checkid setup."
  (remhash handle *requests*)		; Message no longer needed
  (assert (message-field message "openid.return_to"))
  (if (get-parameter "allow") ; Check which of the links was clicked:
      (successful-response-uri op message) ; - Allow
      (cancel-response-uri op message))    ; - Deny
  )


;;; Provider object and Hunchentoot handlers
(defvar *openid-provider* nil
  "OpenID Provider object.")

;; Hunchentoot handles
(defun finish-checkid-handle ()
  (if (not (gethash (get-parameter "handle") *requests*))
      (html "What exactly do you want?"
            "<h2>~:[ACCESS GRANTED~;ACCESS DENIED~]</h2>
<p>But there is no <code>return_to</code> address, so I can only display this screen to you.</p>"
            (get-parameter "allow"))
      (redirect (finish-checkid-setup *openid-provider*))))

(defun provider-ht-handle ()
  (multiple-value-bind (body code)
      (handle-openid-provider-request *openid-provider*
                                      (append (post-parameters*)
                                              (get-parameters*))
                                      :allow-unencrypted-association-p (ssl-p))
    (cond
      ((<= 300 code 399) 			; Redirect, body is actually an URI
       (redirect body :code code))

      (t (setf (return-code*) code)	; Set return code
         body))))

;; Initialization
(defun init-provider (base-uri prefix
                      &aux
                      (endpoint-uri (merge-uris prefix base-uri))
                      (finish-prefix (concatenate 'string prefix "finish-setup"))
                      (finish-uri (merge-uris finish-prefix base-uri)))
  (setf *openid-provider*
        (make-instance 'example-op
                       :endpoint-uri endpoint-uri
                       :finish-uri finish-uri)

        *dispatch-table*
        (nconc (list (create-prefix-dispatcher finish-prefix 'finish-checkid-handle)
                     (create-prefix-dispatcher prefix 'provider-ht-handle))))

  ;; Without this, Hunchentoot does not allow sending error response
  ;; body.
  (pushnew 400 *approved-return-codes*))

; (init-provider "http://example.com/" "/cl-openid-op/")

