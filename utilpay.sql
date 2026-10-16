-- =====================================================
-- UtilPay: Utility Meter Reading & Bill Payment System
-- PostgreSQL script for pgAdmin (Query Tool)
-- Run the whole file once (F5). Re-running is safe.
-- =====================================================

-- 0. Clean slate -------------------------------------
DROP TABLE IF EXISTS payment    CASCADE;
DROP TABLE IF EXISTS billrecord CASCADE;
DROP TABLE IF EXISTS reading    CASCADE;
DROP TABLE IF EXISTS meter      CASCADE;
DROP TABLE IF EXISTS consumer   CASCADE;
DROP FUNCTION IF EXISTS fn_mark_bill_paid() CASCADE;

-- 1. DDL ---------------------------------------------
CREATE TABLE consumer (
  consumer_id SERIAL PRIMARY KEY,
  name        VARCHAR(80)  NOT NULL,
  address     VARCHAR(150) NOT NULL,
  phone       CHAR(10)     NOT NULL UNIQUE
);

CREATE TABLE meter (
  meter_id     SERIAL PRIMARY KEY,
  consumer_id  INT NOT NULL REFERENCES consumer(consumer_id),
  meter_no     VARCHAR(20) NOT NULL UNIQUE,
  install_date DATE NOT NULL,
  UNIQUE (meter_id, consumer_id)
);

CREATE TABLE reading (
  reading_id    SERIAL PRIMARY KEY,
  meter_id      INT NOT NULL REFERENCES meter(meter_id),
  reading_date  DATE NOT NULL,
  reading_value NUMERIC(10,2) NOT NULL CHECK (reading_value >= 0),
  UNIQUE (meter_id, reading_date)
);

CREATE TABLE billrecord (
  bill_id       SERIAL PRIMARY KEY,
  consumer_id   INT NOT NULL,
  meter_id      INT NOT NULL,
  billing_month DATE NOT NULL,
  amount_due    NUMERIC(10,2) NOT NULL CHECK (amount_due > 0),
  due_date      DATE NOT NULL,
  status        VARCHAR(10) NOT NULL DEFAULT 'Unpaid'
                CHECK (status IN ('Unpaid','Paid')),
  UNIQUE (meter_id, billing_month),
  FOREIGN KEY (meter_id, consumer_id) REFERENCES meter(meter_id, consumer_id)
);

CREATE TABLE payment (
  payment_id   SERIAL PRIMARY KEY,
  bill_id      INT NOT NULL REFERENCES billrecord(bill_id),
  payment_date DATE NOT NULL,
  amount_paid  NUMERIC(10,2) NOT NULL CHECK (amount_paid > 0),
  mode         VARCHAR(12) NOT NULL CHECK (mode IN ('UPI','Cash','Card','NetBanking'))
);

-- 2. Trigger (created BEFORE payment data is loaded) --
CREATE OR REPLACE FUNCTION fn_mark_bill_paid() RETURNS TRIGGER AS $$
BEGIN
  UPDATE billrecord b
  SET    status = 'Paid'
  WHERE  b.bill_id = NEW.bill_id
    AND  (SELECT SUM(p.amount_paid) FROM payment p
          WHERE p.bill_id = NEW.bill_id) >= b.amount_due;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_mark_paid
AFTER INSERT ON payment
FOR EACH ROW EXECUTE FUNCTION fn_mark_bill_paid();

-- 3. DML: sample data --------------------------------
INSERT INTO consumer (name, address, phone) VALUES
('Rohan Patil',    'Ambarnath East', '9820011001'),
('Sneha Kulkarni', 'Ambarnath West', '9820011002'),
('Amit Deshmukh',  'Badlapur',       '9820011003'),
('Priya Shinde',   'Ulhasnagar',     '9820011004'),
('Vikram Joshi',   'Kalyan',         '9820011005');

INSERT INTO meter (consumer_id, meter_no, install_date) VALUES
(1,'MH-ELE-1001','2022-03-14'),
(2,'MH-ELE-1002','2022-07-02'),
(3,'MH-ELE-1003','2023-01-19'),
(4,'MH-ELE-1004','2023-09-05'),
(5,'MH-ELE-1005','2024-02-11');

-- Month-end readings in kWh
INSERT INTO reading (meter_id, reading_date, reading_value) VALUES
(1,'2026-06-30',1200),(1,'2026-07-31',1295),(1,'2026-08-31',1410),(1,'2026-09-30',1500),
(2,'2026-06-30', 800),(2,'2026-07-31', 860),(2,'2026-08-31', 925),(2,'2026-09-30',1010),
(3,'2026-06-30',2000),(3,'2026-07-31',2150),(3,'2026-08-31',2310),(3,'2026-09-30',2420),
(4,'2026-06-30', 500),(4,'2026-07-31', 540),(4,'2026-08-31', 580),(4,'2026-09-30', 635),
(5,'2026-06-30',3100),(5,'2026-07-31',3260),(5,'2026-08-31',3395),(5,'2026-09-30',3520);

-- Amount = units consumed in the month x Rs 8 per unit
INSERT INTO billrecord (consumer_id, meter_id, billing_month, amount_due, due_date) VALUES
(1,1,'2026-07-01', 760,'2026-08-15'),
(2,2,'2026-07-01', 480,'2026-08-15'),
(3,3,'2026-07-01',1200,'2026-08-15'),
(4,4,'2026-07-01', 320,'2026-08-15'),
(5,5,'2026-07-01',1280,'2026-08-15'),
(1,1,'2026-08-01', 920,'2026-09-15'),
(2,2,'2026-08-01', 520,'2026-09-15'),
(3,3,'2026-08-01',1280,'2026-09-15');

-- Trigger fires on each insert: bills 1, 2 and 6 become 'Paid'
INSERT INTO payment (bill_id, payment_date, amount_paid, mode) VALUES
(1,'2026-08-10', 760,'UPI'),
(2,'2026-08-12', 480,'Cash'),
(6,'2026-09-10', 920,'UPI');

-- =====================================================
-- 4. QUERIES (select one block and press F5 to run it)
-- =====================================================

-- Q1: consumers with an unpaid bill older than 30 days (subquery)
SELECT c.consumer_id, c.name, c.phone
FROM   consumer c
WHERE  c.consumer_id IN (
         SELECT b.consumer_id
         FROM   billrecord b
         WHERE  b.status = 'Unpaid'
           AND  b.due_date < CURRENT_DATE - INTERVAL '30 days');

-- Q2: monthly consumption from consecutive readings (window function)
SELECT meter_id, reading_date, reading_value,
       reading_value - LAG(reading_value)
         OVER (PARTITION BY meter_id ORDER BY reading_date) AS units_consumed
FROM   reading
ORDER  BY meter_id, reading_date;

-- Q3: outstanding dues per consumer (JOIN + aggregate)
SELECT c.name, COUNT(*) AS unpaid_bills, SUM(b.amount_due) AS total_due
FROM   billrecord b
JOIN   consumer c ON c.consumer_id = b.consumer_id
WHERE  b.status = 'Unpaid'
GROUP  BY c.name
ORDER  BY total_due DESC;

-- Q4: each bill with the total paid so far (LEFT JOIN)
SELECT b.bill_id, c.name, b.amount_due,
       COALESCE(SUM(p.amount_paid), 0) AS paid, b.status
FROM   billrecord b
JOIN   consumer c ON c.consumer_id = b.consumer_id
LEFT   JOIN payment p ON p.bill_id = b.bill_id
GROUP  BY b.bill_id, c.name, b.amount_due, b.status
ORDER  BY b.bill_id;

-- =====================================================
-- 5. TRIGGER TEST (run the statements one at a time)
-- =====================================================

-- Partial payment: bill 7 (Rs 520) stays Unpaid
INSERT INTO payment (bill_id, payment_date, amount_paid, mode)
VALUES (7,'2026-10-01',200,'Card');
SELECT bill_id, status FROM billrecord WHERE bill_id = 7;   -- Unpaid

-- Remaining amount: trigger flips bill 7 to Paid automatically
INSERT INTO payment (bill_id, payment_date, amount_paid, mode)
VALUES (7,'2026-10-02',320,'Card');
SELECT bill_id, status FROM billrecord WHERE bill_id = 7;   -- Paid
