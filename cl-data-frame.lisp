;;; -*- Mode:Lisp; Syntax:ANSI-Common-Lisp; Coding:utf-8 -*-



(cl:defpackage #:cl-data-frame.column
  (:use #:cl
        #:alexandria
        #:anaphora
        #:let-plus)
  (:export
   #:column-length
   #:column-summary)
  (:import-from #:clnu
                #:as-alist))

(cl:in-package #:cl-data-frame.column)

(defgeneric column-length (column)
  (:documentation "Return the length of column.")
  (:method ((column vector))
    (length column)))

(defstruct vector-summary%
  "Base class for summarizing vectors.  Not exported."
  (length 0 :type array-index :read-only t))

(defun print-count-and-percentage (stream count length)
  "Print COUNT as is and also as a rounded percentage of "
  (format stream "~D (~D%)" count (round (/ count length) 1/100)))

(defstruct (bit-vector-summary (:include vector-summary%))
  "Summary of a bit vector."
  (count 0 :type array-index :read-only t))

(defmethod print-object ((summary bit-vector-summary) stream)
  (let+ (((&structure-r/o bit-vector-summary- length count) summary))
    (princ "bits, ones: " stream)
    (print-count-and-percentage stream count length)))

(defstruct quantiles-summary
  "Summary of a real elements (using quantiles)."
  (count 0 :type array-index :read-only t)
  (min 0 :type real :read-only t)
  (q25 0 :type real :read-only t)
  (q50 0 :type real :read-only t)
  (q75 0 :type real :read-only t)
  (max 0 :type real :read-only t))

(defstruct (generic-vector-summary (:include vector-summary%))
  "Summary for generic vectors."
  (quantiles nil :type (or null quantiles-summary) :read-only t)
  (element-count-alist nil :type list :read-only t))

(defun ensure-not-ratio (real)
  "When REAL is a RATIO, convert it to a float, otherwise return as is.  Used for printing."
  (if (typep real 'ratio)
      (float real 1.0)
      real))

(defparameter *column-summary-quantiles-threshold* 10
  "If the number of reals exceeds this threshold, they will be summarized with quantiles.")

(defgeneric column-summary (column)
  (:documentation "Return an object that summarizes COLUMN of a DATA-FRAME.  Primarily intended for printing, not analysis, returned values should print nicely.")
  (:method ((column bit-vector))
    (make-bit-vector-summary :length (length column) :count (count 1 column)))
  (:method ((column vector))
    (let+ ((length (length column))
           (table (aprog1 (clnu:make-sparse-counter :test #'equal)
                    (map nil (curry #'clnu:add it) column)))
           (alist (as-alist table))
           ((&flet real? (item) (realp (car item))))
           (reals-alist (remove-if (complement #'real?) alist))
           (quantiles (when (< *column-summary-quantiles-threshold*
                               (length reals-alist))
                        (let+ ((#(min q25 q50 q75 max)
                                 (clnu:weighted-quantiles
                                  (mapcar #'car reals-alist)
                                  (mapcar #'cdr reals-alist)
                                  #(0 1/4 1/2 3/4 1))))
                          (make-quantiles-summary
                           :count (reduce #'+ reals-alist :key #'cdr)
                           :min min :q25 q25 :q50 q50 :q75 q75 :max max))))
           (alist (stable-sort (if quantiles
                                   (remove-if #'real? alist)
                                   (copy-list alist))
                               #'>= :key #'cdr)))
      (make-generic-vector-summary :length length
                                   :quantiles quantiles
                                   :element-count-alist alist))))

(defmethod print-object ((summary generic-vector-summary) stream)
  (let+ (((&structure-r/o generic-vector-summary- length quantiles
                          element-count-alist) summary))
    #+sbcl ;; complains about unreachable code
    (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
    (pprint-logical-block (stream nil)
      (pprint-logical-block (stream nil)
        (when quantiles
          (let+ (((&structure-r/o quantiles-summary- count min q25 q50 q75 max)
                  quantiles))
            (format stream
                    "~W reals, ~:_min=~W, ~:_q25=~W, ~:_q50=~W, ~:_q75=~W, ~:_max=~W"
                    count min (ensure-not-ratio q25) (ensure-not-ratio q50)
                    (ensure-not-ratio q75) max))))
      (when (and quantiles element-count-alist)
        (format stream "; ")
        (pprint-newline :linear stream))
      (pprint-logical-block (stream element-count-alist)
        (loop (pprint-exit-if-list-exhausted)
              ;; (when quantiles
              ;;   (format stream ", ~@_"))
              (let+ (((element . count) (pprint-pop)))
                (print-count-and-percentage stream count length)
                (format stream " x ~W" element))
              (pprint-exit-if-list-exhausted)
              (format stream ", ~_"))))))


(cl:defpackage #:cl-data-frame
  (:nicknames #:data-frame #:dframe)
  (:use
   #:cl
   #:alexandria
   #:anaphora
   #:let-plus
   #:cl-data-frame.column
   #:cl-slice
   #:cl-slice-dev)
  (:import-from #:clnu #:as-alist)
  (:export
   ;; error messages for ordered keys
   #:duplicate-key
   #:key-not-found
   ;; generic - both data-vector and data-frame
   #:columns
   #:map-columns
   #:column
   #:keys
   #:copy
   #:add-columns
   #:add-column!
   #:add-columns!
   ;; data-vector
   #:data-vector
   #:make-dv
   #:alist-dv
   #:plist-dv
   #:dv
   ;; data-frame
   #:data-frame
   #:make-df
   #:alist-df
   #:plist-df
   #:df
   #:matrix-df
   #:*column-summary-minimum-length*
   ;; transformations for data-frames
   #:map-rows
   #:do-rows
   #:mask-rows
   #:count-rows
   #:map-df
   #:replace-column!
   #:replace-column))

(cl:in-package #:cl-data-frame)

;;; Ordered keys provide a mapping from column keys (symbols) to nonnegative
;;; integers.  They are used internally and the corresponding interface is
;;; NOT EXPORTED.

(defstruct (ordered-keys (:copier nil))
  "Representation of ordered keys.

TABLE maps keys to indexes, starting from zero."
  (table (make-hash-table :test #'eq) :type hash-table :read-only t))

(define-condition duplicate-key (error)
  ((key :initarg :key))
  (:documentation "Duplicate key.")
  (:report (lambda (condition stream)
             (format stream "Duplicate key ~A." (slot-value condition 'key)))))

(define-condition key-not-found (error)
  ((key :initarg :key)
   (keys :initarg :keys))
  (:documentation "Key not found.")
  (:report (lambda (condition stream)
             (format stream "Key ~A not found, valid keys are ~A."
                     (slot-value condition 'key)
                     (slot-value condition 'keys)))))

(defun keys-count (ordered-keys)
  "Number of keys."
  (hash-table-count (ordered-keys-table ordered-keys)))

(defun keys-vector (ordered-keys)
  "Vector of all keys."
  (map 'vector #'car
       (sort (hash-table-alist (ordered-keys-table ordered-keys))
             #'<=
             :key #'cdr)))

(defun key-index (ordered-keys key)
  "Return the index for KEY."
  (let+ (((&values index present?)
          (gethash key (ordered-keys-table ordered-keys))))
    (unless present?
      (error 'key-not-found :key key :keys (keys-vector ordered-keys)))
    index))

(defmethod print-object ((ordered-keys ordered-keys) stream)
  (print-unreadable-object (ordered-keys stream :type t)
    (format stream "~{~a~^, ~}" (coerce (keys-vector ordered-keys) 'list))))

(defun add-key! (ordered-keys key)
  "Modify ORDERED-KEYS by adding KEY."
  (check-type key symbol)
  (let+ (((&structure ordered-keys- table) ordered-keys)
         ((&values &ign present?) (gethash key table)))
    (when present?
      (error 'duplicate-key :key key))
    (setf (gethash key table) (hash-table-count table)))
  ordered-keys)

(defun ordered-keys (keys)
  "Create an ORDERED-KEYS object from KEYS (a sequence)."
  (aprog1 (make-ordered-keys)
    (map nil (curry #'add-key! it) keys)))

(defun copy-ordered-keys (ordered-keys)
  (let+ (((&structure ordered-keys- table) ordered-keys))
    (make-ordered-keys :table (copy-hash-table table))))

(defun add-keys (ordered-keys &rest keys)
  (aprog1 (copy-ordered-keys ordered-keys)
    (mapc (curry #'add-key! it) keys)))

;;; implementation of SLICE for ORDERED-KEYS

(defmethod axis-dimension ((axis ordered-keys))
  (hash-table-count (ordered-keys-table axis)))

(defmethod canonical-representation ((axis ordered-keys) (slice symbol))
  (if (slice-reserved-symbol? slice)
      (call-next-method)
      (key-index axis slice)))

(defmethod slice ((ordered-keys ordered-keys) &rest slices)
  (let+ (((slice) slices))
    (ordered-keys
     (slice (keys-vector ordered-keys)
            (canonical-representation ordered-keys slice)))))


;;; generic implementation -- the class is not exported, only the functionality

(defclass data ()
  ((ordered-keys     :initarg  :ordered-keys     :type     ordered-keys)
   (columns          :initarg  :columns          :type     vector)
   (column-type      :initarg  :column-type      :accessor get-column-type      :type vector)
   (incomplete-cases :initarg  :incomplete-cases :accessor get-incomplete-cases :type vector)
   (print-widths     :accessor get-print-widths  :initarg  :print-widths))
  (:documentation "This class is used for implementing both data-vector and data-matrix, and represents and ordered collection of key-column pairs.  Columns are assumed to be of type column-type (NUMBER, DATE, CATEGORY, STRING).  This class is not exported."))

(defmethod aops:element-type ((data data))
  t)

(defun isna (x)
  (eql x :na))

(defun reduce-column ( function column )
  "reduce a column of a df with function yielding a scalar. If an :na appears in the first rows, handle that, likewise if the column is only 1 item. will need to be optimised"
  
  (let* ((start (loop for i below (length column) while  (isna (aref column i)) finally (return i) ))
	(result (aref column start)))
    (if (> start (length column) )
	result
	(loop  for i from start  below (length column) do
		(if (isna (aref column i))
		    (warn "reducing incomplete case. case ~a skipped~%" i)
		    (setf result (funcall function result (aref  column i))))
	      finally (return result)))))

(defun determine-print-widths (cols types)
  (loop for c in cols and type in types collect
       (1+ (ecase type
	  (NUMBER (log (reduce-column #'max c) 10))
	  (DATE   (log (reduce-column #'max c) 10))
	  (STRING (reduce-column #'max (map 'vector (lambda (item) (if (eql item :na) 3  (length item)) ) c)))
	  (CATEGORY (reduce-column #'max (mapcar (lambda (s) (if (eql s :na) 3  (length (symbol-name s)))) c)))))))


(defun make-data (class keys columns &key (column-types t column-types-supplied-p) (incomplete-cases nil))
  "Create a DATA object from KEYS and COLUMNS.  FOR INTERNAL USE.  Always creates a copy of COLUMNS in order to ensure that it is an adjustable array with a fill pointer.  KEYS are converted to ORDERED-KEYS if necessary. If column types are supplied as a list use them or make everything type t"
  (let* ((n-columns (length columns))
	 (n-rows (length (first columns)))
	 (column-keys keys)
	 (column-types (if column-types-supplied-p
			   column-types
			   (loop repeat n-columns collect t)))
	 (ordered-keys (ordered-keys column-keys)))
    (assert (= n-columns (keys-count ordered-keys) (length column-types)))
    (if incomplete-cases
	(assert (= (length (first columns)) (length incomplete-cases)))
	(setf incomplete-cases (loop repeat n-rows collect nil)))
    (assert (subtypep class 'data))
    (make-instance class
                   :ordered-keys ordered-keys
                   :columns (make-array n-columns
                                        :adjustable t
                                        :fill-pointer n-columns
                                        :initial-contents columns)
		   :column-type (make-array n-columns
					    :adjustable t
					    :fill-pointer n-columns
					    :initial-contents column-types)
		   :incomplete-cases (make-array n-rows
						 :adjustable t
						 :fill-pointer n-rows
						 :initial-contents incomplete-cases)
		   :print-widths (make-array n-columns
						 :adjustable t
						 :fill-pointer n-columns
						 :initial-contents (determine-print-widths columns column-types)))))

(defgeneric check-column-compatibility (data column)
  (:documentation "Check if COLUMN is compatible with DATA.")
  (:method ((data data) column)))

(defun ensure-arguments-alist (rest)
  "Recognizes the following and converts them to an alist:

  plist
  alist
  (plist)
  (alist)
  (data-frame)"
  (let+ (((&flet error% (&optional (list rest))
            (error "Could not interpret ~A as a plist or alist." list)))
         ((&flet ensure-alist (list)
            (typecase (car list)
              (cons rest)
              (symbol (plist-alist rest))
              (t (error% list))))))
    (if (cdr rest)
        (ensure-alist rest)
        (let ((first (car rest)))
          (typecase first
            (data (as-alist first))
            (cons (if (consp (cdr first))
                      (ensure-alist first)
                      rest))            ; first element of an alist
            (t (error%)))))))

(defun alist-data (class alist)
  "Create an object of CLASS (subclass of DATA) from ALIST which contains key-column pairs."
  (assert alist () "Can't create an empty data frame.")
  (make-data class (mapcar #'car alist) (mapcar #'cdr alist)))

(defun plist-data (class plist)
  "Create an object of CLASS (subclass of DATA) from PLIST which contains keys and columns, interleaved."
  (alist-data class (plist-alist plist)))

(defun guess-alist? (plist-or-alist)
  "Test if the argument is an ALIST by checking its first element.  Used for deciding which creation function to call."
  (consp (car plist-or-alist)))

(defun keys (data)
  "List of keys."
  (check-type data data)
  (copy-seq (keys-vector (slot-value data 'ordered-keys))))

(defun types (data)
  "types of each column"
  (check-type data data)
  (copy-seq (slot-value data 'column-type)))

(defun keys-and-types-alist (data)
  "construct an alist of keys and types"
  
  (loop for key across (keys data) and type across (types data) 
     collect (cons key type)))

(defun make-categorical (data key)
  "make a column a categorical variable, convert entries to symbols. Only works on string columns"
  (check-type data data)
  (assert (eql 'string (column-type data key)))
  (let+ ((column (column data key))
	 ((&slots ordered-keys ) data)
	 (count 0))
    (map-into column (lambda (x) (alexandria:symbolicate x)
			(incf count)) column)
    (format t "~a entries processed~%" count)
    (setf (aref (get-column-type data) (key-index ordered-keys key)) :CATEGORY))
  (values))

(defun recode (data key old new)
  "change a value in a column from old to new"
  (check-type data data)
  
  (let+ ((column (column data key))
	 (comparison (ecase (column-type data key)
		       (NUMBER #'=)
		       (DATE #'=)
		       (STRING #'string=)
		       (:CATEGORY #'eql)))
	 (count 0))
    (map-into column (lambda (item) (if (funcall comparison item old)
				   new
				   item)
			(incf count)) column)
   (format t "entries processed ~a~%" count))
  (values))

(defmethod as-alist ((data data))
  "Key-column pairs as an alist."
  (map 'list #'cons (keys data) (columns data)))

(defun copy (data &key (key #'identity))
  "Copy data frame or vector.  Keys are copied (and thus can be modified), columns or elements are copyied using KEY, making the default give a shallow copy."
  (check-type data data)
  (let+ (((&slots-r/o ordered-keys columns) data))
    (make-data (class-of data)
               (keys-and-types-alist  data)
               (map 'vector key columns))))

(defun column (data key)
  "Return column corresponding to key."
  (check-type data data)
  (let+ (((&slots-r/o ordered-keys columns) data))
    (aref columns (key-index ordered-keys key))))

(defun column-type (data key)
  "Return column corresponding to key."
  (check-type data data)
  (let+ (((&slots-r/o ordered-keys column-type) data))
    (aref column-type (key-index ordered-keys key))))

(defun (setf column) (column data key)
  "Set column corresponding to key."
  (check-column-compatibility data column)
  (let+ (((&slots-r/o ordered-keys columns) data))
    (setf (aref columns (key-index ordered-keys key)) column)))

(defun columns (data &optional (slice t))
  "Return the columns as a vector, or a slice if given (keys are resolved)."
  (check-type data data)
  (let+ (((&slots-r/o ordered-keys columns) data))
    (slice columns (canonical-representation ordered-keys slice))))

(defun map-columns (data function &optional (result-class (class-of data)))
  "Map columns of DATA-FRAME or DATA-VECTOR using FUNCTION.  The result is a new DATA-FRAME with the same keys."
  (make-data result-class (keys data) (map 'vector function (columns data))))

(defun add-column! (data key column)
  "Modify DATA (a data-frame or data-vector) by adding COLUMN with KEY.  Return DATA."
  (check-column-compatibility data column)
  (let+ (((&slots ordered-keys columns) data))
    (add-key! ordered-keys key)
    (vector-push-extend column columns))
  data)

(defun add-columns! (data &rest keys-and-columns)
  "Modify DATA (a data-frame or data-vector) by adding columns with keys (see README about accepted argument formats)."
  (mapc (lambda+ ((key . column))
          (add-column! data key column))
        (ensure-arguments-alist keys-and-columns))
  data)

(defun add-columns (data &rest keys-and-columns)
  "Return a new data-frame or data-vector with keys and columns added.  Does not modify DATA (see README about accepted argument formats)."
  (aprog1 (copy data)
    (apply #'add-columns! it keys-and-columns)))

(defmacro define-data-subclass (class abbreviation)
  (check-type class symbol)
  (check-type abbreviation symbol)
  (let+ (((&flet fname (prefix)
            (symbolicate prefix '#:- abbreviation)))
         (alist-fn (fname '#:alist))
         (plist-fn (fname '#:plist)))
    `(progn
       (defclass ,class (data)
         ())
       (defun ,(fname '#:make) (keys columns &key (column-types t) (incomplete-cases nil) )
         (make-data ',class keys columns :column-types column-types :incomplete-cases incomplete-cases) )
       (defun ,alist-fn (alist)
         (alist-data ',class alist))
       (defun ,plist-fn (plist)
         (plist-data ',class plist))
       (defun ,abbreviation (&rest plist-or-alist)
         (if (guess-alist? plist-or-alist)
             (,alist-fn plist-or-alist)
             (,plist-fn plist-or-alist))))))

(define-data-subclass data-vector dv)

(defmethod aops:dims ((data-vector data-vector))
  (list (length (columns data-vector))))

(defmethod aops:as-array ((data-vector data-vector))
  (columns data-vector))

(defmethod print-object ((data-vector data-vector) stream)
  (let ((alist (as-alist data-vector)))
    (pprint-logical-block (stream alist)
      (print-unreadable-object (data-vector stream :type t)
        (format stream "(~d)" (length alist))
        (loop (pprint-exit-if-list-exhausted)
              (let+ (((key . column) (pprint-pop)))
                (format stream "~_ ~W ~W" key column))
              (pprint-exit-if-list-exhausted)
              (princ "," stream))))))

(defmethod slice ((data-vector data-vector) &rest slices)
  (let+ (((column-slice) slices)
         ((&slots-r/o ordered-keys columns) data-vector)
         (column-slice (canonical-representation ordered-keys column-slice)))
    (if (singleton-representation? column-slice)
        (aref columns column-slice)
        (make-dv (slice ordered-keys column-slice)
                 (slice columns column-slice)))))

(define-data-subclass data-frame df)

(defmethod initialize-instance :after ((data-frame data-frame) &rest initargs)
  (declare (ignore initargs))
  (let+ (((first . rest) (coerce (columns data-frame) 'list))
         (length (column-length first)))
    (assert (every (lambda (column)
                     (= length (column-length column)))
                   rest)
            () "Columns don't have the same length.")))

(defmethod aops:nrow ((data-frame data-frame))
  (column-length (aref (columns data-frame) 0)))

(defmethod aops:ncol ((data-frame data-frame))
  (length (columns data-frame)))

(defmethod aops:dims ((data-frame data-frame))
  (list (aops:nrow data-frame) (aops:ncol data-frame)))

(defmethod aops:as-array ((data-frame data-frame))
  ;; Return contents of DATA-FRAME as a matrix.
  (clnu:transpose (aops:combine (columns data-frame))))

(defmethod check-column-compatibility ((data data-frame) column)
  (assert (= (column-length column) (aops:nrow data))))

(defmethod count-incomplete-cases ((data data-frame))
  (count t (get-incomplete-cases data)))

(defmethod print-row ((data data-frame) row )
  (let ((widths (push 10 (get-print-widths data))))
    (format t " ~{~a ~}~%"  row)))

(defmethod row ((data data-frame) index)
  "return row at index as a list with the row number s the first element"
  (let ((columns (map 'list (curry #'column data-frame) (ensure-list (keys data-frame)))))
    (cons index  (mapcar (lambda (column) (ref column index)) columns))))

(defmethod list-incomplete-cases ((data data-frame))
  (let ((nrow (aops:nrow data-frame))
	(incomplete (get-incomplete-cases data-frame)))
    (dotimes (index nrow (values))
      (when (ref incomplete index)
	(print-row  (data row ))))))

(defparameter *column-summary-minimum-length* 10
  "Columns are only summarized when longer than this, otherwise they are returned as is.")
;;
;; previously, columns would be summarized , which for a large data frame resulted in tons of effectively useless output. We just print the first 10 rows of the data frame and provide a function to summarise the df. The column summaries can be printed explicitly when desired
;;
(defmethod print-object ((data-frame data-frame) stream)
  (let ((alist (as-alist data-frame)))
    (pprint-logical-block (stream alist)
      (print-unreadable-object (data-frame stream :type t)
        (format stream "(~d x ~d)~%" (length alist) (aops:nrow data-frame))
	(format stream "Incomplete Cases ~d~%" (count-incomplete-cases data-frame))
        (loop (pprint-exit-if-list-exhausted)
              (pprint-newline :mandatory stream)
              (let+ (((key . column) (pprint-pop)))
                (format stream "~W ~W" key 		
			(subseq  column 0
				 (min *column-summary-minimum-length* (length column))))))))))

(defun summarize (df &key (columns t))
  "print out columns summaries. When columns is t, print all, or just do the columns specified in a list"
  (values ))




(defun matrix-df (keys matrix)
  "Convert a matrix to a data-frame with the given keys."
  (let+ ((columns (aops:split (clnu:transpose matrix) 1)))
    (assert (length= columns keys))
    (alist-df (map 'list #'cons keys columns))))

;;; implementation of SLICE for DATA-FRAME

(defmethod slice ((data-frame data-frame) &rest slices)
  (let+ (((row-slice &optional (column-slice t)) slices)
         ((&slots-r/o ordered-keys columns) data-frame)
         (row-slice (canonical-representation (aops:nrow data-frame) row-slice))
         (column-slice (canonical-representation ordered-keys column-slice))
         (columns (slice columns column-slice))
         ((&flet slice-column (column)
            (slice column row-slice))))
    (if (singleton-representation? column-slice)
        (slice-column columns)
        (let ((keys (slice ordered-keys column-slice))
              (columns (map 'vector #'slice-column columns)))
          (if (singleton-representation? row-slice)
              (make-dv keys columns)
              (make-df keys columns))))))

;;; TODO: (setf slice)

;;; mapping rows and adding columns

(defun map-rows (data-frame keys function &key (element-type t))
  "Map rows using FUNCTION, on the columns corresponding to KEYS.  Return the result with the given ELEMENT-TYPE."
  (let ((columns (map 'list (curry #'column data-frame) (ensure-list keys)))
        (nrow (aops:nrow data-frame)))
    (aprog1 (make-array nrow :element-type element-type)
      (dotimes (index nrow)
        (setf (aref it index)
              (apply function
                     (mapcar (lambda (column)
                               (ref column index))
                             columns)))))))

(defun do-rows (data-frame keys function)
  "Traverse rows from first to last, calling FUNCTION on the columns corresponding to KEYS.  Return no values."
  (let ((columns (map 'list (curry #'column data-frame) (ensure-list keys)))
        (nrow (aops:nrow data-frame)))
    (dotimes (index nrow (values))
      (apply function
             (mapcar (lambda (column)
                       (ref column index))
                     columns)))))

(defun map-df (data-frame keys function result-keys)
  "Map DATA-FRAME to another one by rows.  Function is called on the columns corresponding to KEYS, and should return a sequence with the same length as RESULT-KEYS, which give the keys of the resulting data frame.  RESULT-KETS should be either symbols, or of the format (symbol &optional (element-type t))."
  (let* ((columns (map 'list (curry #'column data-frame) keys))
         (nrow (aops:nrow data-frame))
         (result-keys-and-element-types
           (mapcar (lambda (key-and-element-type)
                     (let+ (((key &optional (element-type t))
                             (ensure-list key-and-element-type)))
                       (cons key element-type)))
                   result-keys))
         (result-columns (map 'vector
                              (lambda (key-and-element-type)
                                (make-array nrow
                                            :element-type (cdr key-and-element-type)))
                              result-keys-and-element-types)))
    (dotimes (index nrow)
      (let ((result-row (apply function
                               (mapcar (lambda (column)
                                         (ref column index))
                                       columns))))
        (assert (length= result-row result-columns))
        (map nil (lambda (result-column result-element)
                   (setf (aref result-column index) result-element))
             result-columns result-row)))
    (make-df (mapcar #'car result-keys-and-element-types) result-columns)))

(defun mask-rows (data-frame keys predicate)
  "Return a bit-vector containing the result of calling PREDICATE on rows of the columns corresponding to KEYS (0 for NIL, 1 otherwise)."
  (map-rows data-frame keys (compose (lambda (flag)
                                       (if flag 1 0))
                                     predicate)
            :element-type 'bit))

(defun count-rows (data-frame keys predicate)
  "Count the number of rows for which PREDICATE called on the columns corresponding to KEYS returns non-NIL."
  (let ((columns (map 'list (curry #'column data-frame) (ensure-list keys))))
    (loop for index below (aops:nrow data-frame)
          count (apply predicate
                       (mapcar (lambda (column)
                                 (ref column index))
                               columns)))))

(defun replace-column! (data key function-or-column &key (element-type t))
  "Modify column KEY of data-frame DATE by replacing it either with the given column, or applying the function to the current values (ELEMENT-TYPE is used.)"
  (let+ (((&slots ordered-keys columns) data)
         (index (key-index ordered-keys key)))
    (setf (aref columns index)
          (if (functionp function-or-column)
              (map-rows data key function-or-column :element-type element-type)
              (prog1 function-or-column
                (check-column-compatibility data function-or-column)))))
  data)

(defun replace-column (data key function-or-column &key (element-type t))
  "Create a new data frame by with new column KEY from data-frame DATE by replacing it either with the given column, or applying the function to the current values (ELEMENT-TYPE is used.)"
  (replace-column! (copy data) key function-or-column :element-type element-type))
