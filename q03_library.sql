-- ICT371 Q3: Library Returns and Overdue Fines  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables
CREATE TABLE books (
  book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE NULL,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id          INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on  DATE NULL,
  new_returned_on  DATE NULL,
  changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
  ('Database System Concepts'), ('Operating Systems'), ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
  (1, 'Alice Mulenga',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- open, overdue
  (2, 'Brian Tembo',     CURRENT_DATE - 10, CURRENT_DATE - 3),   -- returned on due date
  (3, 'Chola Mumba',     CURRENT_DATE - 25, CURRENT_DATE - 15),  -- returned late
  (1, 'Dalitso Phiri',   CURRENT_DATE - 2,  CURRENT_DATE + 12),  -- open, not due
  (2, 'Esther Zimba',    CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- open, not due
  (1, 'Faith Banda',     CURRENT_DATE - 20, CURRENT_DATE - 6);   -- open, overdue

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
  v_due DATE; v_ret DATE; v_end DATE;
BEGIN
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'p_as_of must not be NULL';
  END IF;
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
  END IF;
  v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));   -- stop accruing at return
  RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$ LANGUAGE plpgsql STABLE;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_loan_audit() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loan_audit();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_borrowed DATE; v_due DATE; v_ret DATE;
BEGIN
  IF p_returned_on IS NULL THEN
    RAISE EXCEPTION 'Return date must not be NULL';
  END IF;
  SELECT borrowed_on, due_on, returned_on INTO v_borrowed, v_due, v_ret
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
  END IF;
  IF v_ret IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
  END IF;
  -- return date and final fine are stored together in one UPDATE
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = 2 * GREATEST(p_returned_on - v_due, 0)
  WHERE loan_id = p_loan_id;
END;
$$;

-- Returned loans through the procedure (audit rows created by the trigger)
CALL pr_return_loan(2, CURRENT_DATE - 3);    -- on the due date: fine 0
CALL pr_return_loan(3, CURRENT_DATE - 10);   -- 5 days late: fine K10

-- Tests:
-- SELECT fn_loan_fine(1, CURRENT_DATE);   -- 32
-- CALL pr_return_loan(3, CURRENT_DATE);   -- error: already returned
-- CALL pr_return_loan(99, CURRENT_DATE);  -- error: unknown

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Partial index: only unreturned loans are indexed, by book
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Snapshot procedure.
-- "Unreturned as of p_as_of" = borrowed on/before that date and not returned by it.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule('refresh_overdue_daily', '10 0 * * *',
  $cron$CALL pr_refresh_overdue(CURRENT_DATE)$cron$);

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces same snapshot_date
SELECT * FROM overdue_summary;
SELECT * FROM loan_audit;
