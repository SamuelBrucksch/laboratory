(in-package :db.agraph.http.backend)

(defclass rdf-transaction-parser (net.xml.sax:sax-parser)
  ((actions :initform () :accessor @actions)
   (parts :accessor @parts)
   (expect :accessor @expect)
   (text :accessor @text)
   (ignore-depth :initform 0 :accessor @ignore-depth)
   (context :initform () :accessor @context)))

(defmethod net.xml.sax:start-element ((parser rdf-transaction-parser) iri localname qname attrs)
  (declare (ignore iri qname))
  (flet ((enter-context (from to &rest expect)
           (let ((current (caar (@context parser))))
             (when (eq current :ignore)
               (incf (@ignore-depth parser))
               (return-from enter-context))
             (unless (or (eq from :any) (eq current from))
               (error "Unexpected <~a> tag." localname (caar (@context parser)))))
           (push (cons to attrs) (@context parser))
           (when (eq to :text) (setf (@text parser) ()))
           (when expect
             (setf (@expect parser) expect
                   (@parts parser) ()))))
    (scase localname
      ("transaction" (enter-context nil :top))
      ("add" (enter-context :top :action :part :part :part :contexts))
      ("remove" (enter-context :top :action :maybe :maybe :maybe :contexts))
      ("removeFromNamedContext" (enter-context :top :action :maybe :maybe :maybe :maybe-null))
      ("clear" (enter-context :top :action :contexts))
      (("setNamespace" "removeNamespace" "clearNamespaces") (enter-context :top :leaf))
      (("uri" "bnode" "literal") (enter-context :action :text))
      ("null" (enter-context :action :leaf)))))

(defmethod net.xml.sax:end-element ((parser rdf-transaction-parser) iri localname qname)
  (declare (ignore iri qname))
  (let ((context (pop (@context parser))))
    (flet ((get-parts ()
             (loop :for exp :in (@expect parser)
                   :when (eq exp :part) :do (error "Not enough elements in <~a> tag." localname)
                   :do (unless (eq exp :contexts) (push nil (@parts parser))))
             (nreverse (@parts parser)))
           (action (type args)
             (push (cons type args) (@actions parser)))
           (text ()
             (apply #'concatenate 'string (nreverse (@text parser))))
           (check-expect ()
             (let ((exp (car (@expect parser))))
               (unless (eq exp :contexts) (pop (@expect parser)))
               exp))
           (attribute (name &optional (default nil default-p))
             (or (cdr (assoc name (cdr context) :test #'string=))
                 (if default-p default (error "Missing attribute '~a' in <~a> tag." name localname)))))
      (scase localname
        ("add" (action :add (get-parts)))
        ("remove" (action :remove (get-parts)))
        ("removeFromNamedContext" (action :remove (get-parts)))
        ("clear" (action :remove (list* nil nil nil (@parts parser))))
        ("setNamespace" (action :add-namespace (list (attribute "prefix") (attribute "name"))))
        ("removeNamespace" (action :remove-namespace (list (attribute "prefix"))))
        ("clearNamespaces" (action :clear-namespaces))
        ("uri" (check-expect)
               (push (resource (text)) (@parts parser)))
        ("bnode" (check-expect)
                 (push (list :bnode (text)) (@parts parser)))
        ("literal" (check-expect)
                   (push (literal (text) :language (attribute "xml:lang" nil) :datatype (attribute "datatype" nil))
                         (@parts parser)))
        ("null" (let ((exp (check-expect)))
                  (when (eq exp :part) (error "Unexpected <~a> tag." localname))
                  (push (if (member exp '(:maybe-null :contexts)) :null nil) (@parts parser))))
        ;; Unknown tag, no context was pushed, so don't pop
        (t (push context (@context parser)))))))

(defun add-chars (parser chars)
  (case (caar (@context parser))
    (:text (push chars (@text parser)))
    (:ignore nil)
    (t (when (some (lambda (ch) (not (member ch '(#\space #\tab #\newline #\return)))) chars)
         (error "Stray '~a' in document." (concatenate 'string chars))))))

(defmethod net.xml.sax:content ((parser rdf-transaction-parser) content start end ignorable)
  (declare (ignore ignorable))
  (add-chars parser (subseq content start end)))

(defmethod net.xml.sax:content-character ((parser rdf-transaction-parser) character ignorable)
  (declare (ignore ignorable))
  (add-chars parser (list character)))

(defun parse-rdf-transaction-string (string)
  (let ((parser (make-instance 'rdf-transaction-parser)))
    (net.xml.sax:sax-parse-string string :class parser)
    (nreverse (@actions parser))))

(defun parse-rdf-transaction (file)
  (let ((parser (make-instance 'rdf-transaction-parser)))
    (net.xml.sax:sax-parse-file file :class parser)
    (nreverse (@actions parser))))

(defun apply-rdf-transaction (actions)
  (let ((bnodes (make-hash-table :test 'equal)))
    (flet ((finish (part)
             (etypecase part
               (keyword (default-graph-upi *db*)) ;; :null
               (null nil)
               (cons (or (gethash (second part) bnodes) ;; (:bnode "id")
                         (setf (gethash (second part) bnodes) (new-blank-node))))
               (triple-part part))))
      (dolist (action actions)
        (ecase (car action)
          (:add
           (destructuring-bind (subj pred obj . contexts) (mapcar #'finish (cdr action))
             (dolist (context (or contexts (list (default-graph-upi *db*))))
               (add-triple subj pred obj :g context))))
          (:remove
           (destructuring-bind (subj pred obj . contexts) (mapcar #'finish (cdr action))
             (dolist (context (or contexts (list nil)))
               (delete-triples :s subj :p pred :o obj :g context))))
          (:remove-namespace
           (let ((prefix (second action)))
             (remove-namespace prefix)
             (namespace-request :delete prefix nil)))
          (:add-namespace
           (destructuring-bind (prefix name) (cdr action)
             (register-namespace prefix name :errorp nil)
             (namespace-request :put prefix name)))
          (:clear-namespaces
           (clear-namespaces)
           (namespace-request :delete nil nil)))))))

(defun namespace-request (method name url)
  (let ((path (store-path *store*)))
    (when path
      (let ((uri (net.uri:parse-uri (format nil "~a/namespaces~@[/~a~]" path (and name (url-encode name))))))
        (setf (net.uri:uri-host uri) "localhost"
              (net.uri:uri-port uri) (@frontend-port *server*))
        (multiple-value-bind (body status)
            (net.aserve.client:do-http-request uri
              :method method :content url
              :headers `(("authorization" . ,(header-slot-value *req* :authorization))))
          (unless (member status '(200 204))
            (error "Failed to update namespace: ~a" body)))))))
