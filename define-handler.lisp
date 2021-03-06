(in-package #:house)

;;;;;;;;;; Parameter type parsing.
;;;;; Basics
(defparameter *http-type-priority* (make-hash-table)
  "Priority table for all parameter types. 
Types will be parsed from highest to lowest priority;
parameters with a lower priority can refer to parameters of a higher priority.")

(defgeneric type-expression (parameter type)
  (:documentation
   "A type-expression will tell the server how to convert a parameter from a string to a particular, necessary type."))
(defgeneric type-assertion (parameter type)
  (:documentation
   "A lookup assertion is run on a parameter immediately after conversion. Use it to restrict the space of a particular parameter."))
(defmethod type-expression (parameter type) nil)
(defmethod type-assertion (parameter type) nil)

;;;;; Definition macro
(defmacro define-http-type ((type &key (priority 0)) &key type-expression type-assertion)
  (assert (numberp priority) nil "`priority` should be a number. The highest will be converted first")
  (with-gensyms (tp)
    `(let ((,tp ,type))
       (setf (gethash ,tp *http-type-priority*) ,priority)
       ,@(when type-expression
	   `((defmethod type-expression (parameter (type (eql ,type))) ,type-expression)))
       ,@(when type-assertion
	   `((defmethod type-assertion (parameter (type (eql ,type))) ,type-assertion))))))

;;;;; Common HTTP types
(define-http-type (:string))

(define-http-type (:integer)
    :type-expression `(parse-integer ,parameter :junk-allowed t)
    :type-assertion `(numberp ,parameter))

(define-http-type (:json)
    :type-expression `(json:decode-json-from-string ,parameter))

(define-http-type (:keyword)
    :type-expression `(->keyword ,parameter))

(define-http-type (:list-of-keyword)
    :type-expression `(loop for elem in (json:decode-json-from-string ,parameter)
			 if (stringp elem) collect (->keyword elem)
			 else do (error (make-instance 'http-assertion-error :assertion `(stringp ,elem)))))

(define-http-type (:list-of-integer)
    :type-expression `(json:decode-json-from-string ,parameter)
    :type-assertion `(every #'numberp ,parameter))

;;;;;;;;;; Constructing argument lookups
(defun args-by-type-priority (args &optional (priority-table *http-type-priority*))
  (let ((cpy (copy-list args)))
    (sort cpy #'<= 
	  :key (lambda (arg)
		 (if (listp arg)
		     (gethash (second arg) priority-table 0)
		     0)))))

(defun arg-exp (arg-sym)
  `(aif (cdr (assoc ,(->keyword arg-sym) parameters))
	(uri-decode it)
	(error (make-instance 'http-assertion-error :assertion ',arg-sym))))

(defun arguments (args body)
  (loop with res = body
     for arg in (args-by-type-priority args)
     do (match arg
	  ((guard arg-sym (symbolp arg-sym))
	   (setf res `(let ((,arg-sym ,(arg-exp arg-sym)))
			,res)))
	  ((list* arg-sym type restrictions)
	   (setf res
		 `(let ((,arg-sym ,(or (type-expression (arg-exp arg-sym) type) (arg-exp arg-sym))))
		    ,@(awhen (type-assertion arg-sym type) `((assert-http ,it)))
		    ,@(loop for r in restrictions collect `(assert-http ,r))
		    ,res))))
     finally (return res)))

;;;;;;;;;; Defining Handlers
(defparameter *handlers* (make-hash-table :test 'equal))
(defmacro make-closing-handler ((&key (content-type "text/html")) (&rest args) &body body)
  (with-gensyms (cookie?)
    `(lambda (sock ,cookie? session parameters)
       (declare (ignorable session parameters))
       ,(arguments args
		   `(let ((res (make-instance 
				'response 
				:content-type ,content-type 
				:cookie (unless ,cookie? (token session))
				:body (progn ,@body))))
		      (write! res sock)
		      (socket-close sock))))))

(defmacro make-stream-handler ((&rest args) &body body)
  (with-gensyms (cookie?)
    `(lambda (sock ,cookie? session parameters)
       (declare (ignorable session parameters))
       ,(arguments args
		   `(let ((res (progn ,@body))
			  (stream (flex-stream sock)))
		      (write! (make-instance 'response
					     :keep-alive? t :content-type "text/event-stream" 
					     :cookie (unless ,cookie? (token session))) stream)
		      (crlf stream)
		      (write! (make-instance 'sse :data (or res "Listening...")) stream)
		      (force-output stream))))))

(defmacro bind-handler (name handler)
  (assert (symbolp name) nil "`name` must be a symbol")
  (let ((uri (if (eq name 'root) "/" (format nil "/~(~a~)" name))))
    `(progn
       (when (gethash ,uri *handlers*)
	 (warn ,(format nil "Redefining handler '~a'" uri)))
       (setf (gethash ,uri *handlers*) ,handler))))

(defmacro define-handler ((name &key (close-socket? t) (content-type "text/html")) (&rest args) &body body)
  (if close-socket?
      `(bind-handler ,name (make-closing-handler (:content-type ,content-type) ,args ,@body))
      `(bind-handler ,name (make-stream-handler ,args ,@body))))

(defmacro define-json-handler ((name) (&rest args) &body body)
  `(define-handler (,name :content-type "application/json") ,args
     (json:encode-json-to-string (progn ,@body))))

;;;;; Special case handlers
;;; Don't use these in production. There are better ways.
(defmethod define-file-handler ((path pathname) &key stem-from)
  (cond ((cl-fad:directory-exists-p path)
	 (cl-fad:walk-directory 
	  path 
	  (lambda (fname)
	    (define-file-handler fname :stem-from (or stem-from (format nil "~a" path))))))
	((cl-fad:file-exists-p path)
	 (setf (gethash (path->uri path :stem-from stem-from) *handlers*)
	       (let ((mime (path->mimetype path)))
		 (lambda (sock cookie? session parameters)
		   (declare (ignore cookie? session parameters))
		   (if (cl-fad:file-exists-p path)
		       (with-open-file (s path :direction :input :element-type 'octet)
			 (let ((buf (make-array (file-length s) :element-type 'octet)))
			   (read-sequence buf s)
			   (write! (make-instance 'response :content-type mime :body buf) sock))
			 (socket-close sock))
		       (error! +404+ sock))))))
	(t
	 (warn "Tried serving nonexistent file '~a'" path)))
  nil)

(defmethod define-file-handler ((path string) &key stem-from)
  (define-file-handler (pathname path) :stem-from stem-from))

(defmacro define-redirect-handler ((name &key permanent?) target)
  (with-gensyms (cookie?)
    `(bind-handler 
      ,name
      (lambda (sock ,cookie? session parameters)
	(declare (ignorable sock ,cookie? session parameters))
	(write! (make-instance 
		 'response :response-code ,(if permanent? "301 Moved Permanently" "307 Temporary Redirect")
		 :location ,target :content-type "text/plain"
		 :body "Resource moved...")
		sock)
	(socket-close sock)))))
