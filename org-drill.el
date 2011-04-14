;;; org-drill.el - Self-testing using spaced repetition
;;;
;;; Author: Paul Sexton <eeeickythump@gmail.com>
;;; Version: 2.1
;;; Repository at http://bitbucket.org/eeeickythump/org-drill/
;;;
;;;
;;; Synopsis
;;; ========
;;;
;;; Uses the SuperMemo spaced repetition algorithms to conduct interactive
;;; "drill sessions", where the material to be remembered is presented to the
;;; student in random order. The student rates his or her recall of each item,
;;; and this information is used to schedule the item for later revision.
;;;
;;; Each drill session can be restricted to topics in the current buffer
;;; (default), one or several files, all agenda files, or a subtree. A single
;;; topic can also be drilled.
;;;
;;; Different "card types" can be defined, which present their information to
;;; the student in different ways.
;;;
;;; See the file README.org for more detailed documentation.


(eval-when-compile (require 'cl))
(eval-when-compile (require 'hi-lock))
(require 'org)
(require 'org-learn)


(defgroup org-drill nil
  "Options concerning interactive drill sessions in Org mode (org-drill)."
  :tag "Org-Drill"
  :group 'org-link)



(defcustom org-drill-question-tag
  "drill"
  "Tag which topics must possess in order to be identified as review topics
by `org-drill'."
  :group 'org-drill
  :type 'string)


(defcustom org-drill-maximum-items-per-session
  30
  "Each drill session will present at most this many topics for review.
Nil means unlimited."
  :group 'org-drill
  :type '(choice integer (const nil)))



(defcustom org-drill-maximum-duration
  20
  "Maximum duration of a drill session, in minutes.
Nil means unlimited."
  :group 'org-drill
  :type '(choice integer (const nil)))


(defcustom org-drill-failure-quality
  2
  "If the quality of recall for an item is this number or lower,
it is regarded as an unambiguous failure, and the repetition
interval for the card is reset to 0 days.  If the quality is higher
than this number, it is regarded as successfully recalled, but the
time interval to the next repetition will be lowered if the quality
was near to a fail.

By default this is 2, for SuperMemo-like behaviour. For
Mnemosyne-like behaviour, set it to 1.  Other values are not
really sensible."
  :group 'org-drill
  :type '(choice (const 2) (const 1)))


(defcustom org-drill-forgetting-index
  10
  "What percentage of items do you consider it is 'acceptable' to
forget each drill session? The default is 10%. A warning message
is displayed at the end of the session if the percentage forgotten
climbs above this number."
  :group 'org-drill
  :type 'integer)


(defcustom org-drill-leech-failure-threshold
  15
  "If an item is forgotten more than this many times, it is tagged
as a 'leech' item."
  :group 'org-drill
  :type '(choice integer (const nil)))


(defcustom org-drill-leech-method
  'skip
  "How should 'leech items' be handled during drill sessions?
Possible values:
- nil :: Leech items are treated the same as normal items.
- skip :: Leech items are not included in drill sessions.
- warn :: Leech items are still included in drill sessions,
  but a warning message is printed when each leech item is
  presented."
  :group 'org-drill
  :type '(choice (const 'warn) (const 'skip) (const nil)))


(defface org-drill-visible-cloze-face
  '((t (:foreground "darkseagreen")))
  "The face used to hide the contents of cloze phrases."
  :group 'org-drill)


(defface org-drill-visible-cloze-hint-face
  '((t (:foreground "dark slate blue")))
  "The face used to hide the contents of cloze phrases."
  :group 'org-drill)


(defface org-drill-hidden-cloze-face
  '((t (:foreground "deep sky blue" :background "blue")))
  "The face used to hide the contents of cloze phrases."
  :group 'org-drill)


(defcustom org-drill-use-visible-cloze-face-p
  nil
  "Use a special face to highlight cloze-deleted text in org mode
buffers?"
  :group 'org-drill
  :type 'boolean)


(defcustom org-drill-hide-item-headings-p
  nil
  "Conceal the contents of the main heading of each item during drill
sessions? You may want to enable this behaviour if item headings or tags
contain information that could 'give away' the answer."
  :group 'org-drill
  :type 'boolean)


(defcustom org-drill-new-count-color
  "royal blue"
  "Foreground colour used to display the count of remaining new items
during a drill session."
  :group 'org-drill
  :type 'color)

(defcustom org-drill-mature-count-color
  "green"
  "Foreground colour used to display the count of remaining mature items
during a drill session. Mature items are due for review, but are not new."
  :group 'org-drill
  :type 'color)

(defcustom org-drill-failed-count-color
  "red"
  "Foreground colour used to display the count of remaining failed items
during a drill session."
  :group 'org-drill
  :type 'color)

(defcustom org-drill-done-count-color
  "sienna"
  "Foreground colour used to display the count of reviewed items
during a drill session."
  :group 'org-drill
  :type 'color)


(setplist 'org-drill-cloze-overlay-defaults
          '(display "[...]"
                    face org-drill-hidden-cloze-face
                    window t))

(setplist 'org-drill-hidden-text-overlay
          '(invisible t))


(defvar org-drill-cloze-regexp
  ;; ver 1   "[^][]\\(\\[[^][][^]]*\\]\\)"
  ;; ver 2   "\\(\\[.*?\\]\\|^[^[[:cntrl:]]*?\\]\\|\\[.*?$\\)"
  ;; ver 3!  "\\(\\[.*?\\]\\|\\[.*?[[:cntrl:]]+.*?\\]\\)"
  "\\(\\[[[:cntrl:][:graph:][:space:]]*?\\)\\(\\||.+?\\)\\(\\]\\)")


(defvar org-drill-cloze-keywords
  `((,org-drill-cloze-regexp
     (1 'org-drill-visible-cloze-face nil)
     (2 'org-drill-visible-cloze-hint-face t)
     (3 'org-drill-visible-cloze-face nil)
     )))


(defcustom org-drill-card-type-alist
  '((nil . org-drill-present-simple-card)
    ("simple" . org-drill-present-simple-card)
    ("twosided" . org-drill-present-two-sided-card)
    ("multisided" . org-drill-present-multi-sided-card)
    ("multicloze" . org-drill-present-multicloze)
    ("spanish_verb" . org-drill-present-spanish-verb))
  "Alist associating card types with presentation functions. Each entry in the
alist takes the form (CARDTYPE . FUNCTION), where CARDTYPE is a string
or nil, and FUNCTION is a function which takes no arguments and returns a
boolean value."
  :group 'org-drill
  :type '(alist :key-type (choice string (const nil)) :value-type function))


(defcustom org-drill-spaced-repetition-algorithm
  'sm5
  "Which SuperMemo spaced repetition algorithm to use for scheduling items.
Available choices are:
- SM2 :: the SM2 algorithm, used in SuperMemo 2.0
- SM5 :: the SM5 algorithm, used in SuperMemo 5.0
- Simple8 :: a modified version of the SM8 algorithm. SM8 is used in
  SuperMemo 98. The version implemented here is simplified in that while it
  'learns' the difficulty of each item using quality grades and number of
  failures, it does not modify the matrix of values that
  governs how fast the inter-repetition intervals increase. A method for
  adjusting intervals when items are reviewed early or late has been taken
  from SM11, a later version of the algorithm, and included in Simple8."
  :group 'org-drill
  :type '(choice (const 'sm2) (const 'sm5) (const 'simple8)))



(defcustom org-drill-optimal-factor-matrix
  nil
  "DO NOT CHANGE THE VALUE OF THIS VARIABLE.

Persistent matrix of optimal factors, used by the SuperMemo SM5 algorithm.
The matrix is saved (using the 'customize' facility) at the end of each
drill session.

Over time, values in the matrix will adapt to the individual user's
pace of learning."
  :group 'org-drill
  :type 'sexp)


(defcustom org-drill-add-random-noise-to-intervals-p
  nil
  "If true, the number of days until an item's next repetition
will vary slightly from the interval calculated by the SM2
algorithm. The variation is very small when the interval is
small, but scales up with the interval."
  :group 'org-drill
  :type 'boolean)


(defcustom org-drill-adjust-intervals-for-early-and-late-repetitions-p
  nil
  "If true, when the student successfully reviews an item 1 or more days
before or after the scheduled review date, this will affect that date of
the item's next scheduled review, according to the algorithm presented at
 [[http://www.supermemo.com/english/algsm11.htm#Advanced%20repetitions]].

Items that were reviewed early will have their next review date brought
forward. Those that were reviewed late will have their next review
date postponed further.

Note that this option currently has no effect if the SM2 algorithm
is used."
  :group 'org-drill
  :type 'boolean)


(defcustom org-drill-cram-hours
  12
  "When in cram mode, items are considered due for review if
they were reviewed at least this many hours ago."
  :group 'org-drill
  :type 'integer)


;;; NEW items have never been presented in a drill session before.
;;; MATURE items HAVE been presented at least once before.
;;; - YOUNG mature items were scheduled no more than
;;;   ORG-DRILL-DAYS-BEFORE-OLD days after their last
;;;   repetition. These items will have been learned 'recently' and will have a
;;;   low repetition count.
;;; - OLD mature items have intervals greater than
;;;   ORG-DRILL-DAYS-BEFORE-OLD.
;;; - OVERDUE items are past their scheduled review date by more than
;;;   LAST-INTERVAL * (ORG-DRILL-OVERDUE-INTERVAL-FACTOR - 1) days,
;;;   regardless of young/old status.


(defcustom org-drill-days-before-old
  10
  "When an item's inter-repetition interval rises above this value in days,
it is no longer considered a 'young' (recently learned) item."
  :group 'org-drill
  :type 'integer)


(defcustom org-drill-overdue-interval-factor
  1.2
  "An item is considered overdue if its scheduled review date is
more than (ORG-DRILL-OVERDUE-INTERVAL-FACTOR - 1) * LAST-INTERVAL
days in the past. For example, a value of 1.2 means an additional
20% of the last scheduled interval is allowed to elapse before
the item is overdue. A value of 1.0 means no extra time is
allowed at all - items are immediately considered overdue if
there is even one day's delay in reviewing them. This variable
should never be less than 1.0."
  :group 'org-drill
  :type 'float)


(defcustom org-drill-learn-fraction
  0.5
  "Fraction between 0 and 1 that governs how quickly the spaces
between successive repetitions increase, for all items. The
default value is 0.5. Higher values make spaces increase more
quickly with each successful repetition. You should only change
this in small increments (for example 0.05-0.1) as it has an
exponential effect on inter-repetition spacing."
  :group 'org-drill
  :type 'float)


(defvar *org-drill-session-qualities* nil)
(defvar *org-drill-start-time* 0)
(defvar *org-drill-new-entries* nil)
(defvar *org-drill-dormant-entry-count* 0)
(defvar *org-drill-due-entry-count* 0)
(defvar *org-drill-overdue-entry-count* 0)
(defvar *org-drill-due-tomorrow-count* 0)
(defvar *org-drill-overdue-entries* nil
  "List of markers for items that are considered 'overdue', based on
the value of ORG-DRILL-OVERDUE-INTERVAL-FACTOR.")
(defvar *org-drill-young-mature-entries* nil
  "List of markers for mature entries whose last inter-repetition
interval was <= ORG-DRILL-DAYS-BEFORE-OLD days.")
(defvar *org-drill-old-mature-entries* nil
  "List of markers for mature entries whose last inter-repetition
interval was greater than ORG-DRILL-DAYS-BEFORE-OLD days.")
(defvar *org-drill-failed-entries* nil)
(defvar *org-drill-again-entries* nil)
(defvar *org-drill-done-entries* nil)
(defvar *org-drill-current-item* nil
  "Set to the marker for the item currently being tested.")
(defvar *org-drill-cram-mode* nil
  "Are we in 'cram mode', where all items are considered due
for review unless they were already reviewed in the recent past?")


;;; Make the above settings safe as file-local variables.


(put 'org-drill-question-tag 'safe-local-variable 'stringp)
(put 'org-drill-maximum-items-per-session 'safe-local-variable
     '(lambda (val) (or (integerp val) (null val))))
(put 'org-drill-maximum-duration 'safe-local-variable
     '(lambda (val) (or (integerp val) (null val))))
(put 'org-drill-failure-quality 'safe-local-variable 'integerp)
(put 'org-drill-forgetting-index 'safe-local-variable 'integerp)
(put 'org-drill-leech-failure-threshold 'safe-local-variable 'integerp)
(put 'org-drill-leech-method 'safe-local-variable
     '(lambda (val) (memq val '(nil skip warn))))
(put 'org-drill-use-visible-cloze-face-p 'safe-local-variable 'booleanp)
(put 'org-drill-hide-item-headings-p 'safe-local-variable 'booleanp)
(put 'org-drill-spaced-repetition-algorithm 'safe-local-variable
     '(lambda (val) (memq val '(simple8 sm5 sm2))))
(put 'org-drill-add-random-noise-to-intervals-p 'safe-local-variable 'booleanp)
(put 'org-drill-adjust-intervals-for-early-and-late-repetitions-p
     'safe-local-variable 'booleanp)
(put 'org-drill-cram-hours 'safe-local-variable 'integerp)
(put 'org-drill-learn-fraction 'safe-local-variable 'floatp)
(put 'org-drill-days-before-old 'safe-local-variable 'integerp)
(put 'org-drill-overdue-interval-factor 'safe-local-variable 'floatp)


;;;; Utilities ================================================================


(defun free-marker (m)
  (set-marker m nil))


(defmacro pop-random (place)
  (let ((idx (gensym)))
    `(if (null ,place)
         nil
       (let ((,idx (random (length ,place))))
         (prog1 (nth ,idx ,place)
           (setq ,place (append (subseq ,place 0 ,idx)
                                (subseq ,place (1+ ,idx)))))))))


(defun shuffle-list (list)
  "Randomly permute the elements of LIST (all permutations equally likely)."
  ;; Adapted from 'shuffle-vector' in cookie1.el
  (let ((i 0)
	j
	temp
	(len (length list)))
    (while (< i len)
      (setq j (+ i (random (- len i))))
      (setq temp (nth i list))
      (setf (nth i list) (nth j list))
      (setf (nth j list) temp)
      (setq i (1+ i))))
  list)


(defun round-float (floatnum fix)
  "Round the floating point number FLOATNUM to FIX decimal places.
Example: (round-float 3.56755765 3) -> 3.568"
  (let ((n (expt 10 fix)))
    (/ (float (round (* floatnum n))) n)))


(defun time-to-inactive-org-timestamp (time)
  (format-time-string
   (concat "[" (substring (cdr org-time-stamp-formats) 1 -1) "]")
   time))



(defmacro with-hidden-cloze-text (&rest body)
  `(progn
     (org-drill-hide-clozed-text)
     (unwind-protect
         (progn
           ,@body)
       (org-drill-unhide-clozed-text))))


(defmacro with-hidden-comments (&rest body)
  `(progn
     (if org-drill-hide-item-headings-p
         (org-drill-hide-heading-at-point))
     (org-drill-hide-comments)
     (unwind-protect
         (progn
           ,@body)
       (org-drill-unhide-comments))))


(defun org-drill-days-since-last-review ()
  "Nil means a last review date has not yet been stored for
the item.
Zero means it was reviewed today.
A positive number means it was reviewed that many days ago.
A negative number means the date of last review is in the future --
this should never happen."
  (let ((datestr (org-entry-get (point) "DRILL_LAST_REVIEWED")))
    (when datestr
      (- (time-to-days (current-time))
         (time-to-days (apply 'encode-time
                              (org-parse-time-string datestr)))))))


(defun org-drill-hours-since-last-review ()
  "Like `org-drill-days-since-last-review', but return value is
in hours rather than days."
  (let ((datestr (org-entry-get (point) "DRILL_LAST_REVIEWED")))
    (when datestr
      (floor
       (/ (- (time-to-seconds (current-time))
             (time-to-seconds (apply 'encode-time
                                     (org-parse-time-string datestr))))
          (* 60 60))))))


(defun org-drill-entry-p (&optional marker)
  "Is MARKER, or the point, in a 'drill item'? This will return nil if
the point is inside a subheading of a drill item -- to handle that
situation use `org-part-of-drill-entry-p'."
  (save-excursion
    (when marker
      (org-drill-goto-entry marker))
    (member org-drill-question-tag (org-get-local-tags))))


(defun org-drill-goto-entry (marker)
  (switch-to-buffer (marker-buffer marker))
  (goto-char marker))


(defun org-part-of-drill-entry-p ()
  "Is the current entry either the main heading of a 'drill item',
or a subheading within a drill item?"
  (or (org-drill-entry-p)
      ;; Does this heading INHERIT the drill tag
      (member org-drill-question-tag (org-get-tags-at))))


(defun org-drill-goto-drill-entry-heading ()
  "Move the point to the heading which holds the :drill: tag for this
drill entry."
  (unless (org-at-heading-p)
    (org-back-to-heading))
  (unless (org-part-of-drill-entry-p)
    (error "Point is not inside a drill entry"))
  (while (not (org-drill-entry-p))
    (unless (org-up-heading-safe)
      (error "Cannot find a parent heading that is marked as a drill entry"))))



(defun org-drill-entry-leech-p ()
  "Is the current entry a 'leech item'?"
  (and (org-drill-entry-p)
       (member "leech" (org-get-local-tags))))


;; (defun org-drill-entry-due-p ()
;;   (cond
;;    (*org-drill-cram-mode*
;;     (let ((hours (org-drill-hours-since-last-review)))
;;       (and (org-drill-entry-p)
;;            (or (null hours)
;;                (>= hours org-drill-cram-hours)))))
;;    (t
;;     (let ((item-time (org-get-scheduled-time (point))))
;;       (and (org-drill-entry-p)
;;            (or (not (eql 'skip org-drill-leech-method))
;;                (not (org-drill-entry-leech-p)))
;;            (or (null item-time)         ; not scheduled
;;                (not (minusp             ; scheduled for today/in past
;;                      (- (time-to-days (current-time))
;;                         (time-to-days item-time))))))))))


(defun org-drill-entry-days-overdue ()
  "Returns:
- NIL if the item is not to be regarded as scheduled for review at all.
  This is the case if it is not a drill item, or if it is a leech item
  that we wish to skip, or if we are in cram mode and have already reviewed
  the item within the last few hours.
- 0 if the item is new, or if it scheduled for review today.
- A negative integer - item is scheduled that many days in the future.
- A positive integer - item is scheduled that many days in the past."
  (cond
   (*org-drill-cram-mode*
    (let ((hours (org-drill-hours-since-last-review)))
      (and (org-drill-entry-p)
           (or (null hours)
               (>= hours org-drill-cram-hours))
           0)))
   (t
    (let ((item-time (org-get-scheduled-time (point))))
      (cond
       ((or (not (org-drill-entry-p))
            (and (eql 'skip org-drill-leech-method)
                 (org-drill-entry-leech-p)))
        nil)
       ((null item-time)                ; not scheduled -> due now
        0)
       (t
        (- (time-to-days (current-time))
           (time-to-days item-time))))))))


(defun org-drill-entry-overdue-p (&optional days-overdue last-interval)
  "Returns true if entry that is scheduled DAYS-OVERDUE dasy in the past,
and whose last inter-repetition interval was LAST-INTERVAL, should be
considered 'overdue'. If the arguments are not given they are extracted
from the entry at point."
  (unless days-overdue
    (setq days-overdue (org-drill-entry-days-overdue)))
  (unless last-interval
    (setq last-interval (org-drill-entry-last-interval 1)))
  (and (numberp days-overdue)
       (> days-overdue 1)               ; enforce a sane minimum 'overdue' gap
       ;;(> due org-drill-days-before-overdue)
       (> (/ (+ days-overdue last-interval 1.0) last-interval)
          org-drill-overdue-interval-factor)))



(defun org-drill-entry-due-p ()
  (let ((due (org-drill-entry-days-overdue)))
    (and (not (null due))
         (not (minusp due)))))


(defun org-drill-entry-new-p ()
  (and (org-drill-entry-p)
       (let ((item-time (org-get-scheduled-time (point))))
         (null item-time))))


(defun org-drill-entry-last-quality (&optional default)
  (let ((quality (org-entry-get (point) "DRILL_LAST_QUALITY")))
    (if quality
        (string-to-number quality)
      default)))


(defun org-drill-entry-failure-count ()
  (let ((quality (org-entry-get (point) "DRILL_FAILURE_COUNT")))
    (if quality
        (string-to-number quality)
      0)))


(defun org-drill-entry-average-quality (&optional default)
  (let ((val (org-entry-get (point) "DRILL_AVERAGE_QUALITY")))
    (if val
        (string-to-number val)
      (or default nil))))

(defun org-drill-entry-last-interval (&optional default)
  (let ((val (org-entry-get (point) "DRILL_LAST_INTERVAL")))
    (if val
        (string-to-number val)
      (or default 0))))

(defun org-drill-entry-repeats-since-fail (&optional default)
  (let ((val (org-entry-get (point) "DRILL_REPEATS_SINCE_FAIL")))
    (if val
        (string-to-number val)
      (or default 0))))

(defun org-drill-entry-total-repeats (&optional default)
  (let ((val (org-entry-get (point) "DRILL_TOTAL_REPEATS")))
    (if val
        (string-to-number val)
      (or default 0))))

(defun org-drill-entry-ease (&optional default)
  (let ((val (org-entry-get (point) "DRILL_EASE")))
    (if val
        (string-to-number val)
      default)))


;;; From http://www.supermemo.com/english/ol/sm5.htm
(defun org-drill-random-dispersal-factor ()
  (let ((a 0.047)
        (b 0.092)
        (p (- (random* 1.0) 0.5)))
    (flet ((sign (n)
                 (cond ((zerop n) 0)
                       ((plusp n) 1)
                       (t -1))))
      (/ (+ 100 (* (* (/ -1 b) (log (- 1 (* (/ b a ) (abs p)))))
                   (sign p)))
         100))))


(defun org-drill-early-interval-factor (optimal-factor
                                                optimal-interval
                                                days-ahead)
  "Arguments:
- OPTIMAL-FACTOR: interval-factor if the item had been tested
exactly when it was supposed to be.
- OPTIMAL-INTERVAL: interval for next repetition (days) if the item had been
tested exactly when it was supposed to be.
- DAYS-AHEAD: how many days ahead of time the item was reviewed.

Returns an adjusted optimal factor which should be used to
calculate the next interval, instead of the optimal factor found
in the matrix."
  (let ((delta-ofmax (* (1- optimal-factor)
                    (/ (+ optimal-interval
                          (* 0.6 optimal-interval) -1) (1- optimal-interval)))))
    (- optimal-factor
       (* delta-ofmax (/ days-ahead (+ days-ahead (* 0.6 optimal-interval)))))))


(defun org-drill-get-item-data ()
  "Returns a list of 6 items, containing all the stored recall
  data for the item at point:
- LAST-INTERVAL is the interval in days that was used to schedule the item's
  current review date.
- REPEATS is the number of items the item has been successfully recalled without
  without any failures. It is reset to 0 upon failure to recall the item.
- FAILURES is the total number of times the user has failed to recall the item.
- TOTAL-REPEATS includes both successful and unsuccessful repetitions.
- AVERAGE-QUALITY is the mean quality of recall of the item over
  all its repetitions, successful and unsuccessful.
- EASE is a number reflecting how easy the item is to learn. Higher is easier.
"
  (let ((learn-str (org-entry-get (point) "LEARN_DATA"))
        (repeats (org-drill-entry-total-repeats :missing)))
    (cond
     (learn-str
      (let ((learn-data (or (and learn-str
                                 (read learn-str))
                            (copy-list initial-repetition-state))))
        (list (nth 0 learn-data)        ; last interval
              (nth 1 learn-data)        ; repetitions
              (org-drill-entry-failure-count)
              (nth 1 learn-data)
              (org-drill-entry-last-quality)
              (nth 2 learn-data)        ; EF
              )))
     ((not (eql :missing repeats))
      (list (org-drill-entry-last-interval)
            (org-drill-entry-repeats-since-fail)
            (org-drill-entry-failure-count)
            (org-drill-entry-total-repeats)
            (org-drill-entry-average-quality)
            (org-drill-entry-ease)))
     (t  ; virgin item
      (list 0 0 0 0 nil nil)))))


(defun org-drill-store-item-data (last-interval repeats failures
                                                total-repeats meanq
                                                ease)
  "Stores the given data in the item at point."
  (org-entry-delete (point) "LEARN_DATA")
  (org-set-property "DRILL_LAST_INTERVAL"
                    (number-to-string (round-float last-interval 4)))
  (org-set-property "DRILL_REPEATS_SINCE_FAIL" (number-to-string repeats))
  (org-set-property "DRILL_TOTAL_REPEATS" (number-to-string total-repeats))
  (org-set-property "DRILL_FAILURE_COUNT" (number-to-string failures))
  (org-set-property "DRILL_AVERAGE_QUALITY"
                    (number-to-string (round-float meanq 3)))
  (org-set-property "DRILL_EASE"
                    (number-to-string (round-float ease 3))))



;;; SM2 Algorithm =============================================================


(defun determine-next-interval-sm2 (last-interval n ef quality
                                                  failures meanq total-repeats)
  "Arguments:
- LAST-INTERVAL -- the number of days since the item was last reviewed.
- REPEATS -- the number of times the item has been successfully reviewed
- EF -- the 'easiness factor'
- QUALITY -- 0 to 5

Returns a list: (INTERVAL REPEATS EF FAILURES MEAN TOTAL-REPEATS OFMATRIX), where:
- INTERVAL is the number of days until the item should next be reviewed
- REPEATS is incremented by 1.
- EF is modified based on the recall quality for the item.
- OF-MATRIX is not modified."
  (assert (> n 0))
  (assert (and (>= quality 0) (<= quality 5)))
  (if (<= quality org-drill-failure-quality)
      ;; When an item is failed, its interval is reset to 0,
      ;; but its EF is unchanged
      (list -1 1 ef (1+ failures) meanq (1+ total-repeats)
            org-drill-optimal-factor-matrix)
    ;; else:
    (let* ((next-ef (modify-e-factor ef quality))
           (interval
            (cond
             ((<= n 1) 1)
             ((= n 2)
              (cond
               (org-drill-add-random-noise-to-intervals-p
                (case quality
                  (5 6)
                  (4 4)
                  (3 3)
                  (2 1)
                  (t -1)))
               (t 6)))
             (t (* last-interval next-ef)))))
      (list (if org-drill-add-random-noise-to-intervals-p
                (+ last-interval (* (- interval last-interval)
                                    (org-drill-random-dispersal-factor)))
              interval)
            (1+ n)
            next-ef
            failures meanq (1+ total-repeats)
            org-drill-optimal-factor-matrix))))


;;; SM5 Algorithm =============================================================


(defun inter-repetition-interval-sm5 (last-interval n ef &optional of-matrix)
  (let ((of (get-optimal-factor n ef (or of-matrix
                                         org-drill-optimal-factor-matrix))))
    (if (= 1 n)
	of
      (* of last-interval))))


(defun determine-next-interval-sm5 (last-interval n ef quality
                                                  failures meanq total-repeats
                                                  of-matrix &optional delta-days)
  (if (zerop n) (setq n 1))
  (if (null ef) (setq ef 2.5))
  (assert (> n 0))
  (assert (and (>= quality 0) (<= quality 5)))
  (unless of-matrix
    (setq of-matrix org-drill-optimal-factor-matrix))
  (setq of-matrix (cl-copy-tree of-matrix))

  (setq meanq (if meanq
                  (/ (+ quality (* meanq total-repeats 1.0))
                     (1+ total-repeats))
                quality))

  (let ((next-ef (modify-e-factor ef quality))
        (old-ef ef)
        (new-of (modify-of (get-optimal-factor n ef of-matrix)
                           quality org-drill-learn-fraction))
        (interval nil))
    (when (and org-drill-adjust-intervals-for-early-and-late-repetitions-p
               delta-days (minusp delta-days))
      (setq new-of (org-drill-early-interval-factor
                    (get-optimal-factor n ef of-matrix)
                    (inter-repetition-interval-sm5
                     last-interval n ef of-matrix)
                    delta-days)))

    (setq of-matrix
          (set-optimal-factor n next-ef of-matrix
                              (round-float new-of 3)))     ; round OF to 3 d.p.

    (setq ef next-ef)

    (cond
     ;; "Failed" -- reset repetitions to 0,
     ((<= quality org-drill-failure-quality)
      (list -1 1 old-ef (1+ failures) meanq (1+ total-repeats)
            of-matrix))     ; Not clear if OF matrix is supposed to be
                            ; preserved
     ;; For a zero-based quality of 4 or 5, don't repeat
     ;; ((and (>= quality 4)
     ;;       (not org-learn-always-reschedule))
     ;;  (list 0 (1+ n) ef failures meanq
     ;;        (1+ total-repeats) of-matrix))     ; 0 interval = unschedule
     (t
      (setq interval (inter-repetition-interval-sm5
                      last-interval n ef of-matrix))
      (if org-drill-add-random-noise-to-intervals-p
          (setq interval (+ last-interval
                            (* (- interval last-interval)
                               (org-drill-random-dispersal-factor)))))
      (list interval
            (1+ n)
            ef
            failures
            meanq
            (1+ total-repeats)
            of-matrix)))))


;;; Simple8 Algorithm =========================================================


(defun org-drill-simple8-first-interval (failures)
  "Arguments:
- FAILURES: integer >= 0. The total number of times the item has
  been forgotten, ever.

Returns the optimal FIRST interval for an item which has previously been
forgotten on FAILURES occasions."
  (* 2.4849 (exp (* -0.057 failures))))


(defun org-drill-simple8-interval-factor (ease repetition)
  "Arguments:
- EASE: floating point number >= 1.2. Corresponds to `AF' in SM8 algorithm.
- REPETITION: the number of times the item has been tested.
1 is the first repetition (ie the second trial).
Returns:
The factor by which the last interval should be
multiplied to give the next interval. Corresponds to `RF' or `OF'."
  (+ 1.2 (* (- ease 1.2) (expt org-drill-learn-fraction (log repetition 2)))))


(defun org-drill-simple8-quality->ease (quality)
  "Returns the ease (`AF' in the SM8 algorithm) which corresponds
to a mean item quality of QUALITY."
  (+ (* 0.0542 (expt quality 4))
     (* -0.4848 (expt quality 3))
     (* 1.4916 (expt quality 2))
     (* -1.2403 quality)
     1.4515))


(defun determine-next-interval-simple8 (last-interval repeats quality
                                                      failures meanq totaln
                                                      &optional delta-days)
  "Arguments:
- LAST-INTERVAL -- the number of days since the item was last reviewed.
- REPEATS -- the number of times the item has been successfully reviewed
- EASE -- the 'easiness factor'
- QUALITY -- 0 to 5
- DELTA-DAYS -- how many days overdue was the item when it was reviewed.
  0 = reviewed on the scheduled day. +N = N days overdue.
  -N = reviewed N days early.

Returns the new item data, as a list of 6 values:
- NEXT-INTERVAL
- REPEATS
- EASE
- FAILURES
- AVERAGE-QUALITY
- TOTAL-REPEATS.
See the documentation for `org-drill-get-item-data' for a description of these."
  (assert (>= repeats 0))
  (assert (and (>= quality 0) (<= quality 5)))
  (assert (or (null meanq) (and (>= meanq 0) (<= meanq 5))))
  (let ((next-interval nil))
    (setf meanq (if meanq
                    (/ (+ quality (* meanq totaln 1.0)) (1+ totaln))
                  quality))
    (cond
     ((or (zerop repeats)
          (zerop last-interval))
      (setf next-interval (org-drill-simple8-first-interval failures))
      (incf repeats)
      (incf totaln))
     (t
      (cond
       ((<= quality org-drill-failure-quality)
        (incf failures)
        (setf repeats 0
              next-interval -1))
       (t
        (let* ((use-n
                (if (and
                     org-drill-adjust-intervals-for-early-and-late-repetitions-p
                     (numberp delta-days) (plusp delta-days)
                     (plusp last-interval))
                    (+ repeats (min 1 (/ delta-days last-interval 1.0)))
                  repeats))
               (factor (org-drill-simple8-interval-factor
                        (org-drill-simple8-quality->ease meanq) use-n))
               (next-int (* last-interval factor)))
          (when (and org-drill-adjust-intervals-for-early-and-late-repetitions-p
                     (numberp delta-days) (minusp delta-days))
            ;; The item was reviewed earlier than scheduled.
            (setf factor (org-drill-early-interval-factor
                          factor next-int (abs delta-days))
                  next-int (* last-interval factor)))
          (setf next-interval next-int)
          (incf repeats)
          (incf totaln))))))
    (list
     (if (and org-drill-add-random-noise-to-intervals-p
              (plusp next-interval))
         (+ last-interval (* (- next-interval last-interval)
                             (org-drill-random-dispersal-factor)))
       next-interval)
     repeats
     (org-drill-simple8-quality->ease meanq)
     failures
     meanq
     totaln
     )))




;;; Essentially copied from `org-learn.el', but modified to
;;; optionally call the SM2 function above.
(defun org-drill-smart-reschedule (quality &optional days-ahead)
  "If DAYS-AHEAD is supplied it must be a positive integer. The
item will be scheduled exactly this many days into the future."
  (let ((delta-days (- (time-to-days (current-time))
                   (time-to-days (or (org-get-scheduled-time (point))
                                     (current-time)))))
        (ofmatrix org-drill-optimal-factor-matrix))
    (destructuring-bind (last-interval repetitions failures
                                       total-repeats meanq ease)
        (org-drill-get-item-data)
      (destructuring-bind (next-interval repetitions ease
                                         failures meanq total-repeats
                                         &optional new-ofmatrix)
          (case org-drill-spaced-repetition-algorithm
            (sm5 (determine-next-interval-sm5 last-interval repetitions
                                              ease quality failures
                                              meanq total-repeats ofmatrix))
            (sm2 (determine-next-interval-sm2 last-interval repetitions
                                              ease quality failures
                                              meanq total-repeats))
            (simple8 (determine-next-interval-simple8 last-interval repetitions
                                                      quality failures meanq
                                                      total-repeats
                                                      delta-days)))
        (if (integerp days-ahead)
            (setf next-interval days-ahead))
        (org-drill-store-item-data next-interval repetitions failures
                                   total-repeats meanq ease)
        (if (eql 'sm5 org-drill-spaced-repetition-algorithm)
            (setq org-drill-optimal-factor-matrix new-ofmatrix))

        (cond
         ((= 0 days-ahead)
          (org-schedule t))
         ((minusp days-ahead)
          (org-schedule nil (current-time)))
         (t
          (org-schedule nil (time-add (current-time)
                                      (days-to-time
                                       (round next-interval))))))))))



(defun org-drill-hypothetical-next-review-date (quality)
  "Returns an integer representing the number of days into the future
that the current item would be scheduled, based on a recall quality
of QUALITY."
  (destructuring-bind (last-interval repetitions failures
                                     total-repeats meanq ease)
      (org-drill-get-item-data)
    (destructuring-bind (next-interval repetitions ease
                                       failures meanq total-repeats
                                       &optional ofmatrix)
        (case org-drill-spaced-repetition-algorithm
          (sm5 (determine-next-interval-sm5 last-interval repetitions
                                            ease quality failures
                                            meanq total-repeats
                                            org-drill-optimal-factor-matrix))
          (sm2 (determine-next-interval-sm2 last-interval repetitions
                                            ease quality failures
                                            meanq total-repeats))
          (simple8 (determine-next-interval-simple8 last-interval repetitions
                                                    quality failures meanq
                                                    total-repeats)))
      (cond
       ((not (plusp next-interval))
        0)
       (t
        next-interval)))))



(defun org-drill-hypothetical-next-review-dates ()
  (let ((intervals nil))
    (dotimes (q 6)
      (push (max (or (car intervals) 0)
                 (org-drill-hypothetical-next-review-date q))
            intervals))
    (reverse intervals)))


(defun org-drill-reschedule ()
  "Returns quality rating (0-5), or nil if the user quit."
  (let ((ch nil)
        (input nil)
        (next-review-dates (org-drill-hypothetical-next-review-dates)))
    (save-excursion
      (while (not (memq ch '(?q ?e ?0 ?1 ?2 ?3 ?4 ?5)))
        (setq input (read-key-sequence
                     (if (eq ch ??)
                         (format "0-2 Means you have forgotten the item.
3-5 Means you have remembered the item.

0 - Completely forgot.
1 - Even after seeing the answer, it still took a bit to sink in.
2 - After seeing the answer, you remembered it.
3 - It took you awhile, but you finally remembered. (+%s days)
4 - After a little bit of thought you remembered. (+%s days)
5 - You remembered the item really easily. (+%s days)

How well did you do? (0-5, ?=help, e=edit, t=tags, q=quit)"
                                 (round (nth 3 next-review-dates))
                                 (round (nth 4 next-review-dates))
                                 (round (nth 5 next-review-dates)))
                       "How well did you do? (0-5, ?=help, e=edit, q=quit)")))
        (cond
         ((stringp input)
          (setq ch (elt input 0)))
         ((and (vectorp input) (symbolp (elt input 0)))
          (case (elt input 0)
            (up (ignore-errors (forward-line -1)))
            (down (ignore-errors (forward-line 1)))
            (left (ignore-errors (backward-char)))
            (right (ignore-errors (forward-char)))
            (prior (ignore-errors (scroll-down))) ; pgup
            (next (ignore-errors (scroll-up)))))  ; pgdn
         ((and (vectorp input) (listp (elt input 0))
               (eventp (elt input 0)))
          (case (car (elt input 0))
            (wheel-up (ignore-errors (mwheel-scroll (elt input 0))))
            (wheel-down (ignore-errors (mwheel-scroll (elt input 0)))))))
        (if (eql ch ?t)
            (org-set-tags-command))))
    (cond
     ((and (>= ch ?0) (<= ch ?5))
      (let ((quality (- ch ?0))
            (failures (org-drill-entry-failure-count)))
        (save-excursion
          (org-drill-smart-reschedule quality
                                      (nth quality next-review-dates)))
        (push quality *org-drill-session-qualities*)
        (cond
         ((<= quality org-drill-failure-quality)
          (when org-drill-leech-failure-threshold
            ;;(setq failures (if failures (string-to-number failures) 0))
            ;; (org-set-property "DRILL_FAILURE_COUNT"
            ;;                   (format "%d" (1+ failures)))
            (if (> (1+ failures) org-drill-leech-failure-threshold)
                (org-toggle-tag "leech" 'on))))
         (t
          (let ((scheduled-time (org-get-scheduled-time (point))))
            (when scheduled-time
              (message "Next review in %d days"
                       (- (time-to-days scheduled-time)
                          (time-to-days (current-time))))
              (sit-for 0.5)))))
        (org-set-property "DRILL_LAST_QUALITY" (format "%d" quality))
        (org-set-property "DRILL_LAST_REVIEWED"
                          (time-to-inactive-org-timestamp (current-time)))
        quality))
     ((= ch ?e)
      'edit)
     (t
      nil))))


(defun org-drill-hide-all-subheadings-except (heading-list)
  "Returns a list containing the position of each immediate subheading of
the current topic."
  (let ((drill-entry-level (org-current-level))
        (drill-sections nil)
        (drill-heading nil))
    (org-show-subtree)
    (save-excursion
      (org-map-entries
       (lambda ()
         (when (and (not (outline-invisible-p))
                    (> (org-current-level) drill-entry-level))
           (setq drill-heading (org-get-heading t))
           (unless (and (= (org-current-level) (1+ drill-entry-level))
                        (member drill-heading heading-list))
             (hide-subtree))
           (push (point) drill-sections)))
       "" 'tree))
    (reverse drill-sections)))


(defun org-drill-presentation-prompt (&rest fmt-and-args)
  (let* ((item-start-time (current-time))
         (input nil)
         (ch nil)
         (last-second 0)
         (mature-entry-count (+ (length *org-drill-young-mature-entries*)
                                (length *org-drill-old-mature-entries*)
                                (length *org-drill-overdue-entries*)))
         (prompt
          (if fmt-and-args
              (apply 'format
                     (first fmt-and-args)
                     (rest fmt-and-args))
            (concat "Press key for answer, "
                    "e=edit, t=tags, s=skip, q=quit."))))
    (setq prompt
          (format "%s %s %s %s %s"
                  (propertize
                   (number-to-string (length *org-drill-done-entries*))
                   'face `(:foreground ,org-drill-done-count-color)
                   'help-echo "The number of items you have reviewed this session.")
                  (propertize
                   (number-to-string (+ (length *org-drill-again-entries*)
                                        (length *org-drill-failed-entries*)))
                   'face `(:foreground ,org-drill-failed-count-color)
                   'help-echo (concat "The number of items that you failed, "
                                      "and need to review again."))
                  (propertize
                   (number-to-string mature-entry-count)
                   'face `(:foreground ,org-drill-mature-count-color)
                   'help-echo "The number of old items due for review.")
                  (propertize
                   (number-to-string (length *org-drill-new-entries*))
                   'face `(:foreground ,org-drill-new-count-color)
                   'help-echo (concat "The number of new items that you "
                                      "have never reviewed."))
                  prompt))
    (if (and (eql 'warn org-drill-leech-method)
             (org-drill-entry-leech-p))
        (setq prompt (concat
                      (propertize "!!! LEECH ITEM !!!
You seem to be having a lot of trouble memorising this item.
Consider reformulating the item to make it easier to remember.\n"
                                  'face '(:foreground "red"))
                      prompt)))
    (while (memq ch '(nil ?t))
      (setq ch nil)
      (while (not (input-pending-p))
        (let ((elapsed (time-subtract (current-time) item-start-time)))
          (message (concat (if (>= (time-to-seconds elapsed) (* 60 60))
                               "++:++ "
                             (format-time-string "%M:%S " elapsed))
                           prompt))
          (sit-for 1)))
      (setq input (read-key-sequence nil))
      (if (stringp input) (setq ch (elt input 0)))
      (if (eql ch ?t)
          (org-set-tags-command)))
    (case ch
      (?q nil)
      (?e 'edit)
      (?s 'skip)
      (otherwise t))))


(defun org-pos-in-regexp (pos regexp &optional nlines)
  (save-excursion
    (goto-char pos)
    (org-in-regexp regexp nlines)))


(defun org-drill-hide-region (beg end)
  "Hide the buffer region between BEG and END with an 'invisible text'
visual overlay."
  (let ((ovl (make-overlay beg end)))
    (overlay-put ovl 'category
                 'org-drill-hidden-text-overlay)))


(defun org-drill-hide-heading-at-point ()
  (unless (org-at-heading-p)
    (error "Point is not on a heading."))
  (save-excursion
    (let ((beg (point)))
      (end-of-line)
      (org-drill-hide-region beg (point)))))


(defun org-drill-hide-comments ()
  (save-excursion
    (while (re-search-forward "^#.*$" nil t)
      (org-drill-hide-region (match-beginning 0) (match-end 0)))))


(defun org-drill-unhide-comments ()
  ;; This will also unhide the item's heading.
  (save-excursion
    (dolist (ovl (overlays-in (point-min) (point-max)))
      (when (eql 'org-drill-hidden-text-overlay (overlay-get ovl 'category))
        (delete-overlay ovl)))))


(defun org-drill-hide-clozed-text ()
  (save-excursion
    (while (re-search-forward org-drill-cloze-regexp nil t)
      ;; Don't hide org links, partly because they might contain inline
      ;; images which we want to keep visible
      (unless (org-pos-in-regexp (match-beginning 0)
                                 org-bracket-link-regexp 1)
        (org-drill-hide-matched-cloze-text)))))


(defun org-drill-hide-matched-cloze-text ()
  "Hide the current match with a 'cloze' visual overlay."
  (let ((ovl (make-overlay (match-beginning 0) (match-end 0))))
    (overlay-put ovl 'category
                 'org-drill-cloze-overlay-defaults)
    (when (find ?| (match-string 0))
      (overlay-put ovl
                   'display
                   (format "[...%s]"
                           (substring-no-properties
                            (match-string 0)
                            (1+ (position ?| (match-string 0)))
                            (1- (length (match-string 0)))))))))


(defun org-drill-unhide-clozed-text ()
  (save-excursion
    (dolist (ovl (overlays-in (point-min) (point-max)))
      (when (eql 'org-drill-cloze-overlay-defaults (overlay-get ovl 'category))
        (delete-overlay ovl)))))



;;; Presentation functions ====================================================

;; Each of these is called with point on topic heading.  Each needs to show the
;; topic in the form of a 'question' or with some information 'hidden', as
;; appropriate for the card type. The user should then be prompted to press a
;; key. The function should then reveal either the 'answer' or the entire
;; topic, and should return t if the user chose to see the answer and rate their
;; recall, nil if they chose to quit.

(defun org-drill-present-simple-card ()
  (with-hidden-comments
   (with-hidden-cloze-text
    (org-drill-hide-all-subheadings-except nil)
    (org-display-inline-images t)
    (org-cycle-hide-drawers 'all)
    (prog1 (org-drill-presentation-prompt)
      (org-show-subtree)))))


(defun org-drill-present-two-sided-card ()
  (with-hidden-comments
   (with-hidden-cloze-text
    (let ((drill-sections (org-drill-hide-all-subheadings-except nil)))
      (when drill-sections
        (save-excursion
          (goto-char (nth (random (min 2 (length drill-sections)))
                          drill-sections))
          (org-show-subtree)))
      (org-display-inline-images t)
      (org-cycle-hide-drawers 'all)
      (prog1
          (org-drill-presentation-prompt)
        (org-show-subtree))))))



(defun org-drill-present-multi-sided-card ()
  (with-hidden-comments
   (with-hidden-cloze-text
    (let ((drill-sections (org-drill-hide-all-subheadings-except nil)))
      (when drill-sections
        (save-excursion
          (goto-char (nth (random (length drill-sections)) drill-sections))
          (org-show-subtree)))
      (org-display-inline-images t)
      (org-cycle-hide-drawers 'all)
      (prog1
          (org-drill-presentation-prompt)
        (org-show-subtree))))))


(defun org-drill-present-multicloze ()
  (with-hidden-comments
   (let ((item-end nil)
         (match-count 0)
         (body-start (or (cdr (org-get-property-block))
                         (point))))
     (org-drill-hide-all-subheadings-except nil)
     (save-excursion
       (outline-next-heading)
       (setq item-end (point)))
     (save-excursion
       (goto-char body-start)
       (while (re-search-forward org-drill-cloze-regexp item-end t)
         (incf match-count)))
     (when (plusp match-count)
       (save-excursion
         (goto-char body-start)
         (re-search-forward org-drill-cloze-regexp
                            item-end t (1+ (random match-count)))
         (org-drill-hide-matched-cloze-text)))
     (org-display-inline-images t)
     (org-cycle-hide-drawers 'all)
     (prog1 (org-drill-presentation-prompt)
       (org-show-subtree)
       (org-drill-unhide-clozed-text)))))


(defun org-drill-present-spanish-verb ()
  (let ((prompt nil)
        (reveal-headings nil))
    (with-hidden-comments
     (with-hidden-cloze-text
      (case (random 6)
        (0
         (org-drill-hide-all-subheadings-except '("Infinitive"))
         (setq prompt
               (concat "Translate this Spanish verb, and conjugate it "
                       "for the *present* tense.")
               reveal-headings '("English" "Present Tense" "Notes")))
        (1
         (org-drill-hide-all-subheadings-except '("English"))
         (setq prompt (concat "For the *present* tense, conjugate the "
                              "Spanish translation of this English verb.")
               reveal-headings '("Infinitive" "Present Tense" "Notes")))
        (2
         (org-drill-hide-all-subheadings-except '("Infinitive"))
         (setq prompt (concat "Translate this Spanish verb, and "
                              "conjugate it for the *past* tense.")
               reveal-headings '("English" "Past Tense" "Notes")))
        (3
         (org-drill-hide-all-subheadings-except '("English"))
         (setq prompt (concat "For the *past* tense, conjugate the "
                              "Spanish translation of this English verb.")
               reveal-headings '("Infinitive" "Past Tense" "Notes")))
        (4
         (org-drill-hide-all-subheadings-except '("Infinitive"))
         (setq prompt (concat "Translate this Spanish verb, and "
                              "conjugate it for the *future perfect* tense.")
               reveal-headings '("English" "Future Perfect Tense" "Notes")))
        (5
         (org-drill-hide-all-subheadings-except '("English"))
         (setq prompt (concat "For the *future perfect* tense, conjugate the "
                              "Spanish translation of this English verb.")
               reveal-headings '("Infinitive" "Future Perfect Tense" "Notes"))))
      (org-cycle-hide-drawers 'all)
      (prog1
          (org-drill-presentation-prompt prompt)
        (org-drill-hide-all-subheadings-except reveal-headings))))))



(defun org-drill-entry ()
  "Present the current topic for interactive review, as in `org-drill'.
Review will occur regardless of whether the topic is due for review or whether
it meets the definition of a 'review topic' used by `org-drill'.

Returns a quality rating from 0 to 5, or nil if the user quit, or the symbol
EDIT if the user chose to exit the drill and edit the current item. Choosing
the latter option leaves the drill session suspended; it can be resumed
later using `org-drill-resume'.

See `org-drill' for more details."
  (interactive)
  (org-drill-goto-drill-entry-heading)
  ;;(unless (org-part-of-drill-entry-p)
  ;;  (error "Point is not inside a drill entry"))
  ;;(unless (org-at-heading-p)
  ;;  (org-back-to-heading))
  (let ((card-type (org-entry-get (point) "DRILL_CARD_TYPE"))
        (cont nil))
    (save-restriction
      (org-narrow-to-subtree)
      (org-show-subtree)
      (org-cycle-hide-drawers 'all)

      (let ((presentation-fn (cdr (assoc card-type org-drill-card-type-alist))))
        (cond
         (presentation-fn
          (setq cont (funcall presentation-fn)))
         (t
          (error "Unknown card type: '%s'" card-type))))

      (cond
       ((not cont)
        (message "Quit")
        nil)
       ((eql cont 'edit)
        'edit)
       ((eql cont 'skip)
        'skip)
       (t
        (save-excursion
          (org-drill-reschedule)))))))


(defun org-drill-entries-pending-p ()
  (or *org-drill-again-entries*
      (and (not (org-drill-maximum-item-count-reached-p))
           (not (org-drill-maximum-duration-reached-p))
           (or *org-drill-new-entries*
               *org-drill-failed-entries*
               *org-drill-young-mature-entries*
               *org-drill-old-mature-entries*
               *org-drill-overdue-entries*
               *org-drill-again-entries*))))


(defun org-drill-pending-entry-count ()
  (+ (length *org-drill-new-entries*)
     (length *org-drill-failed-entries*)
     (length *org-drill-young-mature-entries*)
     (length *org-drill-old-mature-entries*)
     (length *org-drill-overdue-entries*)
     (length *org-drill-again-entries*)))


(defun org-drill-maximum-duration-reached-p ()
  "Returns true if the current drill session has continued past its
maximum duration."
  (and org-drill-maximum-duration
       *org-drill-start-time*
       (> (- (float-time (current-time)) *org-drill-start-time*)
          (* org-drill-maximum-duration 60))))


(defun org-drill-maximum-item-count-reached-p ()
  "Returns true if the current drill session has reached the
maximum number of items."
  (and org-drill-maximum-items-per-session
       (>= (length *org-drill-done-entries*)
           org-drill-maximum-items-per-session)))


(defun org-drill-pop-next-pending-entry ()
  (block org-drill-pop-next-pending-entry
    (let ((m nil))
      (while (or (null m)
                 (not (org-drill-entry-p m)))
        (setq
         m
         (cond
          ;; First priority is items we failed in a prior session.
          ((and *org-drill-failed-entries*
                (not (org-drill-maximum-item-count-reached-p))
                (not (org-drill-maximum-duration-reached-p)))
           (pop-random *org-drill-failed-entries*))
          ;; Next priority is overdue items.
          ((and *org-drill-overdue-entries*
                (not (org-drill-maximum-item-count-reached-p))
                (not (org-drill-maximum-duration-reached-p)))
           (pop-random *org-drill-overdue-entries*))
          ;; Next priority is 'young' items.
          ((and *org-drill-young-mature-entries*
                (not (org-drill-maximum-item-count-reached-p))
                (not (org-drill-maximum-duration-reached-p)))
           (pop-random *org-drill-young-mature-entries*))
          ;; Next priority is newly added items, and older entries.
          ;; We pool these into a single group.
          ((and (or *org-drill-new-entries*
                    *org-drill-old-mature-entries*)
                (not (org-drill-maximum-item-count-reached-p))
                (not (org-drill-maximum-duration-reached-p)))
           (if (< (random (+ (length *org-drill-new-entries*)
                             (length *org-drill-old-mature-entries*)))
                  (length *org-drill-new-entries*))
               (pop-random *org-drill-new-entries*)
             ;; else
             (pop-random *org-drill-old-mature-entries*)))
          ;; After all the above are done, last priority is items
          ;; that were failed earlier THIS SESSION.
          (*org-drill-again-entries*
           (pop-random *org-drill-again-entries*))
          (t                            ; nothing left -- return nil
           (return-from org-drill-pop-next-pending-entry nil)))))
      m)))


(defun org-drill-entries (&optional resuming-p)
  "Returns nil, t, or a list of markers representing entries that were
'failed' and need to be presented again before the session ends.

RESUMING-P is true if we are resuming a suspended drill session."
  (block org-drill-entries
    (while (org-drill-entries-pending-p)
      (let ((m (cond
                ((or (not resuming-p)
                     (null *org-drill-current-item*)
                     (not (org-drill-entry-p *org-drill-current-item*)))
                 (org-drill-pop-next-pending-entry))
                (t                      ; resuming a suspended session.
                 (setq resuming-p nil)
                 *org-drill-current-item*))))
        (setq *org-drill-current-item* m)
        (unless m
          (error "Unexpectedly ran out of pending drill items"))
        (save-excursion
          (org-drill-goto-entry m)
          (setq result (org-drill-entry))
          (cond
           ((null result)
            (message "Quit")
            (setq end-pos :quit)
            (return-from org-drill-entries nil))
           ((eql result 'edit)
            (setq end-pos (point-marker))
            (return-from org-drill-entries nil))
           ((eql result 'skip)
            nil)                        ; skip this item
           (t
            (cond
             ((<= result org-drill-failure-quality)
              (push m *org-drill-again-entries*))
             (t
              (push m *org-drill-done-entries*))))))))))



(defun org-drill-final-report ()
  (let ((pass-percent
         (round (* 100 (count-if (lambda (qual)
                                   (> qual org-drill-failure-quality))
                                 *org-drill-session-qualities*))
                (max 1 (length *org-drill-session-qualities*))))
        (prompt nil))
    (setq prompt
          (format
           "%d items reviewed. Session duration %s.
%d/%d items awaiting review (%s, %s, %s, %s, %s).
Tomorrow, %d more items will become due for review.

Recall of reviewed items:
 Excellent (5):     %3d%%   |   Near miss (2):      %3d%%
 Good (4):          %3d%%   |   Failure (1):        %3d%%
 Hard (3):          %3d%%   |   Abject failure (0): %3d%%

You successfully recalled %d%% of reviewed items (quality > %s)
Session finished. Press a key to continue..."
           (length *org-drill-done-entries*)
           (format-seconds "%h:%.2m:%.2s"
                           (- (float-time (current-time)) *org-drill-start-time*))
           (org-drill-pending-entry-count)
           (+ (org-drill-pending-entry-count)
              *org-drill-dormant-entry-count*)
           (propertize
            (format "%d failed"
                    (+ (length *org-drill-failed-entries*)
                       (length *org-drill-again-entries*)))
            'face `(:foreground ,org-drill-failed-count-color))
           (propertize
            (format "%d overdue"
                    (length *org-drill-overdue-entries*))
            'face `(:foreground ,org-drill-failed-count-color))
           (propertize
            (format "%d new"
                    (length *org-drill-new-entries*))
            'face `(:foreground ,org-drill-new-count-color))
           (propertize
            (format "%d young"
                    (length *org-drill-young-mature-entries*))
            'face `(:foreground ,org-drill-mature-count-color))
           (propertize
            (format "%d old"
                    (length *org-drill-old-mature-entries*))
            'face `(:foreground ,org-drill-mature-count-color))
           *org-drill-due-tomorrow-count*
           (round (* 100 (count 5 *org-drill-session-qualities*))
                  (max 1 (length *org-drill-session-qualities*)))
           (round (* 100 (count 2 *org-drill-session-qualities*))
                  (max 1 (length *org-drill-session-qualities*)))
           (round (* 100 (count 4 *org-drill-session-qualities*))
                  (max 1 (length *org-drill-session-qualities*)))
           (round (* 100 (count 1 *org-drill-session-qualities*))
                  (max 1 (length *org-drill-session-qualities*)))
           (round (* 100 (count 3 *org-drill-session-qualities*))
                  (max 1 (length *org-drill-session-qualities*)))
           (round (* 100 (count 0 *org-drill-session-qualities*))
                  (max 1 (length *org-drill-session-qualities*)))
           pass-percent
           org-drill-failure-quality
           ))

    (while (not (input-pending-p))
      (message "%s" prompt)
      (sit-for 0.5))
    (read-char-exclusive)

    (if (< pass-percent (- 100 org-drill-forgetting-index))
        (read-char-exclusive
         (format
          "%s
You failed %d%% of the items you reviewed during this session.
%d (%d%%) of all items scanned were overdue.

Are you keeping up with your items, and reviewing them
when they are scheduled? If so, you may want to consider
lowering the value of `org-drill-learn-fraction' slightly in
order to make items appear more frequently over time."
          (propertize "WARNING!" 'face 'org-warning)
          (- 100 pass-percent)
          *org-drill-overdue-entry-count*
          (round (* 100 *org-drill-overdue-entry-count*)
                 (+ *org-drill-dormant-entry-count*
                    *org-drill-due-entry-count*)))
         ))))


(defun org-drill (&optional scope resume-p)
  "Begin an interactive 'drill session'. The user is asked to
review a series of topics (headers). Each topic is initially
presented as a 'question', often with part of the topic content
hidden. The user attempts to recall the hidden information or
answer the question, then presses a key to reveal the answer. The
user then rates his or her recall or performance on that
topic. This rating information is used to reschedule the topic
for future review.

Org-drill proceeds by:

- Finding all topics (headings) in SCOPE which have either been
  used and rescheduled before, or which have a tag that matches
  `org-drill-question-tag'.

- All matching topics which are either unscheduled, or are
  scheduled for the current date or a date in the past, are
  considered to be candidates for the drill session.

- If `org-drill-maximum-items-per-session' is set, a random
  subset of these topics is presented. Otherwise, all of the
  eligible topics will be presented.

SCOPE determines the scope in which to search for
questions.  It is passed to `org-map-entries', and can be any of:

nil     The current buffer, respecting the restriction if any.
        This is the default.
tree    The subtree started with the entry at point
file    The current buffer, without restriction
file-with-archives
        The current buffer, and any archives associated with it
agenda  All agenda files
agenda-with-archives
        All agenda files with any archive files associated with them
 (file1 file2 ...)
        If this is a list, all files in the list will be scanned.

If RESUME-P is non-nil, resume a suspended drill session rather
than starting a new one."

  (interactive)
  (let ((end-pos nil)
        (cnt 0))
    (block org-drill
      (unless resume-p
        (setq *org-drill-current-item* nil
              *org-drill-done-entries* nil
              *org-drill-dormant-entry-count* 0
              *org-drill-due-entry-count* 0
              *org-drill-due-tomorrow-count* 0
              *org-drill-overdue-entry-count* 0
              *org-drill-new-entries* nil
              *org-drill-overdue-entries* nil
              *org-drill-young-mature-entries* nil
              *org-drill-old-mature-entries* nil
              *org-drill-failed-entries* nil
              *org-drill-again-entries* nil)
        (setq *org-drill-session-qualities* nil)
        (setq *org-drill-start-time* (float-time (current-time))))
      (unwind-protect
          (save-excursion
            (unless resume-p
              (let ((org-trust-scanner-tags t))
                (org-map-entries
                 (lambda ()
                   (when (zerop (% (incf cnt) 50))
                     (message "Processing drill items: %4d%s"
                              (+ (length *org-drill-new-entries*)
                                 (length *org-drill-overdue-entries*)
                                 (length *org-drill-young-mature-entries*)
                                 (length *org-drill-old-mature-entries*)
                                 (length *org-drill-failed-entries*))
                              (make-string (ceiling cnt 50) ?.)))
                   (let ((due (org-drill-entry-days-overdue))
                         (last-int (org-drill-entry-last-interval 1)))
                   (cond
                    ((not (org-drill-entry-p))
                     nil)               ; skip
                    ((or (null due)     ; unscheduled - usually a skipped leech
                         (minusp due))  ; scheduled in the future
                     (incf *org-drill-dormant-entry-count*)
                     (if (eq -1 due)
                         (incf *org-drill-due-tomorrow-count*)))
                    ((org-drill-entry-new-p)
                     (push (point-marker) *org-drill-new-entries*))
                    ((<= (org-drill-entry-last-quality 9999)
                         org-drill-failure-quality)
                     ;; Mature entries that were failed last time are FAILED,
                     ;; regardless of how young, old or overdue they are.
                     (push (point-marker) *org-drill-failed-entries*))
                    ((org-drill-entry-overdue-p due last-int)
                     ;; Overdue status overrides young versus old distinction.
                     (push (point-marker) *org-drill-overdue-entries*))
                    ((<= (org-drill-entry-last-interval 9999)
                         org-drill-days-before-old)
                     ;; Item is 'young'.
                     (push (point-marker) *org-drill-young-mature-entries*))
                    (t
                     (push (point-marker) *org-drill-old-mature-entries*)))))
                 (concat "+" org-drill-question-tag) scope)))
            (setq *org-drill-due-entry-count* (org-drill-pending-entry-count))
            (setq *org-drill-overdue-entry-count*
                  (length *org-drill-overdue-entries*))
            (cond
             ((and (null *org-drill-new-entries*)
                   (null *org-drill-failed-entries*)
                   (null *org-drill-overdue-entries*)
                   (null *org-drill-young-mature-entries*)
                   (null *org-drill-old-mature-entries*))
              (message "I did not find any pending drill items."))
             (t
              (org-drill-entries resume-p)
              (message "Drill session finished!"))))
        (progn
          (unless end-pos
            (dolist (m (append  *org-drill-done-entries*
                                *org-drill-new-entries*
                                *org-drill-failed-entries*
                                *org-drill-again-entries*
                                *org-drill-overdue-entries*
                                *org-drill-young-mature-entries*
                                *org-drill-old-mature-entries*))
              (free-marker m))))))
    (cond
     (end-pos
      (when (markerp end-pos)
        (org-drill-goto-entry end-pos))
      (message
       "You can continue the drill session with `M-x org-drill-resume'."))
     (t
      (org-drill-final-report)
      (if (eql 'sm5 org-drill-spaced-repetition-algorithm)
          (org-drill-save-optimal-factor-matrix))
      ))))


(defun org-drill-save-optimal-factor-matrix ()
  (message "Saving optimal factor matrix...")
  (customize-save-variable 'org-drill-optimal-factor-matrix
                           org-drill-optimal-factor-matrix))


(defun org-drill-cram (&optional scope)
  "Run an interactive drill session in 'cram mode'. In cram mode,
all drill items are considered to be due for review, unless they
have been reviewed within the last `org-drill-cram-hours'
hours."
  (interactive)
  (let ((*org-drill-cram-mode* t))
    (org-drill scope)))


(defun org-drill-resume ()
  "Resume a suspended drill session. Sessions are suspended by
exiting them with the `edit' option."
  (interactive)
  (org-drill nil t))


(add-hook 'org-mode-hook
          (lambda ()
            (if org-drill-use-visible-cloze-face-p
                (font-lock-add-keywords
                 'org-mode
                 org-drill-cloze-keywords
                 t))))



(provide 'org-drill)
