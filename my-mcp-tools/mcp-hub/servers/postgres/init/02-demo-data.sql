-- SYNTHETIC DEMO DATA. Every name, SSN, card number, account number and salary below is fabricated
-- (random, generated from a fixed seed) for data-loss-prevention demos. No real people are represented.
-- Card numbers are Luhn-valid so DLP detectors recognise them; they are not real accounts.
-- Runs once, on an empty data volume, after 01-roles.sh (which created schema demo and the default grants).

SET search_path = demo;

CREATE TABLE customers (
    id            serial PRIMARY KEY,
    full_name     text NOT NULL,
    email         text NOT NULL UNIQUE,
    phone         text,
    street        text,
    city          text,
    state         char(2),
    zip           text,
    date_of_birth date,
    ssn           text,
    credit_card   text,
    card_expiry   text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE customers IS 'Synthetic demo customers, including sensitive PII (SSN, credit card).';
COMMENT ON COLUMN customers.ssn IS 'US Social Security Number (synthetic), format AAA-GG-SSSS';
COMMENT ON COLUMN customers.credit_card IS 'Payment card number on file (synthetic, Luhn-valid)';
COMMENT ON COLUMN customers.card_expiry IS 'Card expiry MM/YY';

CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id int NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    product     text NOT NULL,
    quantity    int NOT NULL CHECK (quantity > 0),
    unit_price  numeric(10,2) NOT NULL,
    status      text NOT NULL CHECK (status IN ('pending','shipped','delivered','cancelled','refunded')),
    ordered_at  timestamptz NOT NULL
);
COMMENT ON TABLE orders IS 'Synthetic demo orders; total = quantity * unit_price.';

CREATE TABLE payments (
    id          serial PRIMARY KEY,
    order_id    int NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    amount      numeric(10,2) NOT NULL,
    method      text NOT NULL CHECK (method IN ('card','bank_transfer','paypal')),
    card_number text,
    paid_at     timestamptz NOT NULL
);
COMMENT ON TABLE payments IS 'Synthetic demo payments for orders.';
COMMENT ON COLUMN payments.card_number IS 'Full card number used for the payment (synthetic), when method = card';

CREATE TABLE employees (
    id                  serial PRIMARY KEY,
    full_name           text NOT NULL,
    email               text NOT NULL UNIQUE,
    department          text NOT NULL,
    title               text NOT NULL,
    salary_usd          numeric(10,2) NOT NULL,
    ssn                 text,
    bank_routing_number text,
    bank_account_number text,
    hired_on            date NOT NULL
);
COMMENT ON TABLE employees IS 'Synthetic demo employees, including salary, SSN and payroll bank details.';

INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Kimberly Thompson','kimberly.thompson@example.com','(355) 555-3294','6084 Forest St','Atlanta','GA','69593','1980-04-28','625-38-0265','5105-7005-3982-7004','04/28','2024-05-23T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Thomas Clark','thomas.clark@example.com','(496) 555-5347','7600 Highland St','Nashville','TN','38977','1981-06-09','828-93-3586','6011-3435-8127-1754','06/29','2024-02-18T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Linda Wright','linda.wright@example.com','(304) 555-1302','5700 Hill St','Portland','OR','19749','1952-10-17','215-99-5149','3462-544485-36561','10/29','2025-06-17T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Paul Green','paul.green@example.com','(357) 555-5519','7402 Spring St','Nashville','TN','58586','2000-05-08','012-52-3184','5297-1969-5938-0673','02/29','2025-03-29T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Karen Martin','karen.martin@example.com','(808) 555-4522','789 Sunset St','Miami','FL','88429','1951-05-22','630-94-3446','3477-797853-18875','12/29','2024-11-14T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Ronald Martin','ronald.martin@example.com','(793) 555-6361','5936 Pine St','Columbus','OH','96039','1972-11-29','460-72-2527','4307-5045-5085-9972','07/28','2025-08-12T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Deborah Taylor','deborah.taylor@example.com','(780) 555-8581','3903 Forest St','Columbus','OH','79279','1998-12-20','889-79-7921','4786-5877-5521-7625','12/31','2024-01-09T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('William Garcia','william.garcia@example.com','(813) 555-1814','9265 Park St','San Jose','CA','53151','1965-06-29','221-11-0601','6011-4881-4242-9902','09/31','2024-10-11T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Susan Gonzalez','susan.gonzalez@example.com','(631) 555-6971','8760 Elm St','Chicago','IL','66604','1993-05-22','706-65-5226','4045-7759-8618-9955','10/28','2025-04-24T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Deborah Wilson','deborah.wilson@example.com','(987) 555-6988','7400 Oak St','Phoenix','AZ','65677','1986-07-16','353-77-3706','4397-6229-0484-6692','05/29','2024-01-22T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Kimberly Nguyen','kimberly.nguyen@example.com','(938) 555-0921','9200 Highland St','Atlanta','GA','39383','1951-12-23','781-07-4193','4589-0270-3770-8959','02/28','2025-01-26T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Patricia Lopez','patricia.lopez@example.com','(780) 555-5809','8927 Oak St','Chicago','IL','18216','1952-09-20','699-42-9305','4269-8484-2796-5702','10/29','2025-03-05T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Jennifer Roberts','jennifer.roberts@example.com','(566) 555-8307','2287 Highland St','Seattle','WA','62290','1978-07-15','608-52-2183','4243-0280-1318-8867','09/30','2024-03-22T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Donald Miller','donald.miller@example.com','(482) 555-4745','6389 Oak St','Chicago','IL','37132','1994-11-15','805-13-3399','4145-5697-5911-1596','03/28','2025-04-04T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Kevin Martinez','kevin.martinez@example.com','(962) 555-2408','6556 Park St','San Jose','CA','37107','1983-11-15','074-96-3623','5496-4364-8861-0979','12/31','2025-06-20T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Steven Hill','steven.hill@example.com','(595) 555-8110','357 Maple St','Portland','OR','80389','1971-10-29','505-36-8233','5497-8746-3014-5529','09/27','2024-01-12T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Sarah Carter','sarah.carter@example.com','(412) 555-5494','4698 Spring St','Phoenix','AZ','22626','1981-09-24','559-88-7488','5270-1540-3904-1782','10/28','2024-01-02T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('William Perez','william.perez@example.com','(726) 555-2861','2798 Forest St','Portland','OR','54127','1977-07-07','565-42-4847','5550-4611-1619-1500','07/31','2024-01-05T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('George Martin','george.martin@example.com','(826) 555-7410','3454 Main St','Nashville','TN','29383','1992-02-09','736-54-1037','6011-0918-0885-8297','01/28','2024-09-24T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Karen Clark','karen.clark@example.com','(920) 555-0952','652 Maple St','Seattle','WA','89590','1987-12-24','131-42-5262','4872-1255-1186-6214','04/31','2024-12-30T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Elizabeth Rivera','elizabeth.rivera@example.com','(541) 555-8092','7185 Lake St','Phoenix','AZ','11554','1998-08-27','755-69-9468','4860-6172-3004-0489','07/29','2025-03-01T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Linda Walker','linda.walker@example.com','(768) 555-1869','1791 Pine St','Atlanta','GA','86736','1998-04-08','284-70-0992','5160-5267-8764-3476','03/29','2024-02-04T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Barbara Mitchell','barbara.mitchell@example.com','(241) 555-9458','2599 Park St','San Jose','CA','23057','1971-08-20','107-67-4063','6011-5343-0104-1630','10/30','2024-06-21T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Kimberly Torres','kimberly.torres@example.com','(637) 555-0318','9399 Forest St','Atlanta','GA','20521','1988-04-24','194-09-3174','4792-2167-2831-2154','11/31','2025-06-30T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Karen Allen','karen.allen@example.com','(802) 555-6944','7273 Highland St','Chicago','IL','48714','1970-09-24','075-67-2948','3412-681493-28149','05/27','2025-08-14T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Thomas Walker','thomas.walker@example.com','(984) 555-6172','7508 Cedar St','San Jose','CA','65500','1991-11-17','811-52-5771','5519-0760-4224-6820','10/29','2024-08-05T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Brian Taylor','brian.taylor@example.com','(568) 555-5878','6279 Hill St','Boston','MA','50101','1964-09-15','002-88-1927','3449-585471-81531','12/29','2024-12-25T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Patricia Sanchez','patricia.sanchez@example.com','(305) 555-1345','8454 Forest St','Columbus','OH','24681','1990-01-07','368-58-1742','5288-4636-4778-1915','07/31','2025-07-17T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Betty Green','betty.green@example.com','(394) 555-0805','9155 Hill St','Portland','OR','33632','1995-01-16','113-49-3626','6011-4319-9093-3021','09/28','2025-02-18T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Kimberly Nelson','kimberly.nelson@example.com','(552) 555-2406','8426 Oak St','Portland','OR','43963','1986-02-05','857-05-9377','5158-1337-0947-1088','12/31','2024-04-29T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Jessica Davis','jessica.davis@example.com','(370) 555-1437','6590 River St','Denver','CO','97139','1970-09-10','109-01-0064','4195-6519-5714-0061','10/27','2024-11-05T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Andrew Nelson','andrew.nelson@example.com','(676) 555-9104','3669 Pine St','San Jose','CA','80339','1952-12-10','273-13-6856','5152-5106-8612-7468','08/28','2025-05-06T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Joshua Nelson','joshua.nelson@example.com','(429) 555-1070','1031 River St','Denver','CO','58716','1963-03-05','609-43-8692','4228-2989-9963-7406','01/31','2024-10-19T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Emily Taylor','emily.taylor@example.com','(369) 555-1354','4602 Sunset St','San Jose','CA','74452','1954-02-26','373-07-2060','5421-8281-6894-2500','12/30','2025-05-30T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Charles Ramirez','charles.ramirez@example.com','(802) 555-3531','6301 Cedar St','Seattle','WA','84809','1975-03-27','822-02-4661','5129-4548-5395-9652','02/29','2024-12-25T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Betty Roberts','betty.roberts@example.com','(540) 555-1456','4020 Maple St','San Jose','CA','34415','1950-05-07','087-68-0528','5106-4523-8560-7861','01/28','2024-07-28T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Betty Hernandez','betty.hernandez@example.com','(945) 555-8907','3763 Main St','Phoenix','AZ','83597','1962-04-19','764-53-7779','4256-1877-8842-1806','02/27','2024-07-27T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Nancy Miller','nancy.miller@example.com','(771) 555-1844','4285 Washington St','Seattle','WA','45667','1976-08-02','811-11-2566','5120-0570-2618-7264','03/31','2024-05-13T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Barbara Moore','barbara.moore@example.com','(577) 555-9384','4722 Sunset St','Phoenix','AZ','44331','1976-08-29','861-17-3774','4893-5755-4210-8819','10/29','2024-12-31T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Charles Hall','charles.hall@example.com','(295) 555-9248','2099 Forest St','Atlanta','GA','46546','1958-03-21','076-01-3443','4706-1774-1165-9803','10/29','2024-02-04T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('George Smith','george.smith@example.com','(473) 555-8008','7357 Hill St','Boston','MA','96916','1986-10-23','618-44-4878','3745-384864-75095','09/30','2024-06-28T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Charles Nelson','charles.nelson@example.com','(817) 555-6846','8290 Main St','Chicago','IL','23549','1975-08-25','404-47-7445','5437-0218-9006-2043','09/29','2024-01-22T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Mary Allen','mary.allen@example.com','(930) 555-7125','9776 Maple St','Boston','MA','28673','1978-08-13','216-53-9967','4508-8207-1646-3575','01/30','2025-01-21T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Andrew Davis','andrew.davis@example.com','(518) 555-5817','2632 Forest St','Nashville','TN','66844','1969-04-22','057-56-9210','5387-3637-2647-7163','09/30','2025-02-24T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Emily Mitchell','emily.mitchell@example.com','(459) 555-8936','5208 Cedar St','Portland','OR','59298','1999-05-25','189-88-9905','5592-0328-0404-5769','11/28','2024-02-11T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Thomas Williams','thomas.williams@example.com','(487) 555-9976','6793 Hill St','Denver','CO','87158','1981-05-03','061-11-8362','5269-7448-2594-9439','02/28','2024-02-03T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('David Baker','david.baker@example.com','(481) 555-9253','1681 Spring St','Phoenix','AZ','17160','1991-10-20','219-71-3046','5214-8311-4534-2381','12/29','2024-07-13T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Stephanie Rivera','stephanie.rivera@example.com','(528) 555-3011','9877 Maple St','San Jose','CA','50119','1950-11-22','543-17-1269','4736-5029-0228-0781','03/29','2025-08-05T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Joshua Mitchell','joshua.mitchell@example.com','(818) 555-1681','5149 Forest St','Seattle','WA','63427','2000-05-08','126-32-0345','4372-4048-4440-6989','04/30','2025-03-12T00:00:00+08');
INSERT INTO customers (full_name,email,phone,street,city,state,zip,date_of_birth,ssn,credit_card,card_expiry,created_at) VALUES ('Patricia Garcia','patricia.garcia@example.com','(767) 555-4276','1769 Sunset St','Chicago','IL','29413','1977-07-21','685-03-8822','6011-0965-1197-3119','05/31','2024-11-05T00:00:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (20,'Firewall Appliance',1,2499.00,'cancelled','2025-06-02T15:55:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (1,2499.00,'card','4872-1255-1186-6214','2025-06-02T15:58:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (46,'Webcam HD',5,79.00,'delivered','2025-12-14T02:00:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (2,395.00,'card','5269-7448-2594-9439','2025-12-14T02:50:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (47,'Firewall Appliance',2,2499.00,'shipped','2025-01-17T05:54:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (3,4998.00,'card','5214-8311-4534-2381','2025-01-17T07:11:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (12,'Webcam HD',1,79.00,'delivered','2025-01-20T17:16:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (4,79.00,'card','4269-8484-2796-5702','2025-01-20T19:13:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (44,'Endpoint Agent (1yr)',1,59.00,'delivered','2025-08-20T08:13:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (5,59.00,'card','5387-3637-2647-7163','2025-08-20T09:25:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'Webcam HD',1,79.00,'delivered','2026-05-14T06:59:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (6,79.00,'paypal',NULL,'2026-05-14T07:00:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (43,'External SSD 2TB',1,159.00,'cancelled','2026-06-04T11:16:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (7,159.00,'card','4508-8207-1646-3575','2026-06-04T11:53:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (21,'Firewall Appliance',2,2499.00,'delivered','2025-02-09T15:40:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (8,4998.00,'paypal',NULL,'2025-02-09T16:35:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (15,'Wireless Mouse',1,29.99,'refunded','2025-10-10T22:01:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (9,29.99,'bank_transfer',NULL,'2025-10-10T23:12:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (49,'External SSD 2TB',1,159.00,'delivered','2025-08-20T14:51:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (10,159.00,'card','4372-4048-4440-6989','2025-08-20T15:02:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (30,'Laptop Pro 14',5,1899.00,'shipped','2026-01-12T00:39:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (11,9495.00,'card','5158-1337-0947-1088','2026-01-12T00:52:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'Endpoint Agent (1yr)',1,59.00,'delivered','2025-06-17T03:48:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (12,59.00,'bank_transfer',NULL,'2025-06-17T05:24:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (1,'Firewall Appliance',2,2499.00,'delivered','2025-07-29T13:37:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (13,4998.00,'card','5105-7005-3982-7004','2025-07-29T15:06:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (16,'27in Monitor',1,349.00,'delivered','2025-12-01T06:47:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (14,349.00,'card','5497-8746-3014-5529','2025-12-01T07:40:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (2,'Laptop Pro 14',1,1899.00,'pending','2025-01-30T06:26:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (32,'27in Monitor',2,349.00,'cancelled','2025-09-23T21:25:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (16,698.00,'bank_transfer',NULL,'2025-09-23T22:25:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (33,'Firewall Appliance',3,2499.00,'shipped','2025-02-07T14:00:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (17,7497.00,'card','4228-2989-9963-7406','2025-02-07T15:48:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (32,'Wireless Mouse',2,29.99,'delivered','2025-10-11T10:10:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (18,59.98,'card','5152-5106-8612-7468','2025-10-11T11:21:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (41,'External SSD 2TB',2,159.00,'delivered','2025-01-17T03:02:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (19,318.00,'card','3745-384864-75095','2025-01-17T03:07:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (22,'Wireless Mouse',1,29.99,'pending','2025-11-17T18:31:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (45,'Webcam HD',2,79.00,'delivered','2025-08-26T12:09:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (21,158.00,'card','5592-0328-0404-5769','2025-08-26T12:18:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (37,'27in Monitor',2,349.00,'pending','2026-03-09T11:31:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (35,'External SSD 2TB',5,159.00,'cancelled','2025-08-04T02:24:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (23,795.00,'card','5129-4548-5395-9652','2025-08-04T04:16:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (35,'Noise-Cancelling Headset',1,249.00,'shipped','2026-06-04T16:00:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (24,249.00,'card','5129-4548-5395-9652','2026-06-04T16:43:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (46,'Endpoint Agent (1yr)',3,59.00,'delivered','2025-06-29T09:30:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (25,177.00,'paypal',NULL,'2025-06-29T10:50:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'External SSD 2TB',1,159.00,'delivered','2026-02-15T07:14:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (26,159.00,'bank_transfer',NULL,'2026-02-15T08:39:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (46,'VPN License (1yr)',5,99.00,'delivered','2025-12-27T00:01:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (27,495.00,'card','5269-7448-2594-9439','2025-12-27T00:24:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (18,'Webcam HD',5,79.00,'cancelled','2025-09-24T07:28:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (28,395.00,'paypal',NULL,'2025-09-24T08:44:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (16,'Firewall Appliance',1,2499.00,'shipped','2025-06-26T12:25:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (29,2499.00,'bank_transfer',NULL,'2025-06-26T14:11:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (37,'VPN License (1yr)',1,99.00,'delivered','2026-06-06T00:19:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (30,99.00,'card','4256-1877-8842-1806','2026-06-06T00:47:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (42,'Mechanical Keyboard',1,129.00,'delivered','2026-01-30T23:26:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (31,129.00,'bank_transfer',NULL,'2026-01-30T23:33:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (25,'Webcam HD',2,79.00,'shipped','2025-09-27T09:21:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (32,158.00,'card','3412-681493-28149','2025-09-27T10:59:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (47,'Webcam HD',3,79.00,'delivered','2026-02-13T04:43:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (33,237.00,'bank_transfer',NULL,'2026-02-13T06:17:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (49,'27in Monitor',2,349.00,'shipped','2025-12-27T07:56:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (34,698.00,'card','4372-4048-4440-6989','2025-12-27T09:22:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (19,'External SSD 2TB',1,159.00,'shipped','2026-03-26T11:20:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (35,159.00,'card','6011-0918-0885-8297','2026-03-26T13:09:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (15,'Wireless Mouse',3,29.99,'delivered','2025-02-24T23:26:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (36,89.97,'paypal',NULL,'2025-02-24T23:41:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (20,'Webcam HD',3,79.00,'shipped','2025-06-10T10:04:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (37,237.00,'card','4872-1255-1186-6214','2025-06-10T11:22:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (7,'Endpoint Agent (1yr)',5,59.00,'delivered','2026-06-10T23:38:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (38,295.00,'card','4786-5877-5521-7625','2026-06-11T00:05:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (43,'Mechanical Keyboard',1,129.00,'shipped','2025-11-19T02:06:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (39,129.00,'bank_transfer',NULL,'2025-11-19T03:42:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (48,'Smartphone X',3,999.00,'shipped','2025-08-31T04:42:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (40,2997.00,'paypal',NULL,'2025-08-31T06:02:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (15,'Endpoint Agent (1yr)',5,59.00,'cancelled','2026-06-10T03:37:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (41,295.00,'card','5496-4364-8861-0979','2026-06-10T05:02:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'USB-C Dock',1,189.00,'delivered','2025-01-12T07:19:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (42,189.00,'card','6011-4319-9093-3021','2025-01-12T08:25:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (5,'Firewall Appliance',2,2499.00,'delivered','2025-05-26T04:11:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (43,4998.00,'card','3477-797853-18875','2025-05-26T04:27:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (33,'Endpoint Agent (1yr)',1,59.00,'delivered','2025-07-29T09:19:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (44,59.00,'card','4228-2989-9963-7406','2025-07-29T09:25:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (14,'Wireless Mouse',1,29.99,'shipped','2025-09-24T09:19:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (45,29.99,'bank_transfer',NULL,'2025-09-24T11:14:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (8,'Webcam HD',1,79.00,'pending','2025-07-09T15:35:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'Noise-Cancelling Headset',2,249.00,'delivered','2026-03-12T13:47:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (47,498.00,'paypal',NULL,'2026-03-12T15:44:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (31,'Webcam HD',1,79.00,'delivered','2025-01-23T19:39:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (48,79.00,'card','4195-6519-5714-0061','2025-01-23T20:52:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (30,'Webcam HD',3,79.00,'delivered','2026-06-18T14:34:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (49,237.00,'card','5158-1337-0947-1088','2026-06-18T14:53:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (8,'27in Monitor',2,349.00,'delivered','2026-01-09T06:37:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (50,698.00,'card','6011-4881-4242-9902','2026-01-09T07:56:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (1,'Webcam HD',1,79.00,'delivered','2025-07-01T07:02:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (51,79.00,'card','5105-7005-3982-7004','2025-07-01T08:05:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (26,'Smartphone X',2,999.00,'shipped','2026-06-30T07:35:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (52,1998.00,'card','5519-0760-4224-6820','2026-06-30T08:43:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (3,'Laptop Pro 14',5,1899.00,'delivered','2025-10-15T04:00:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (53,9495.00,'card','3462-544485-36561','2025-10-15T05:22:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (2,'External SSD 2TB',5,159.00,'delivered','2025-02-01T19:44:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (54,795.00,'card','6011-3435-8127-1754','2025-02-01T20:40:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (38,'Wireless Mouse',2,29.99,'shipped','2025-05-29T20:45:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (55,59.98,'card','5120-0570-2618-7264','2025-05-29T21:57:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (49,'USB-C Dock',5,189.00,'delivered','2026-07-10T02:49:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (56,945.00,'card','4372-4048-4440-6989','2026-07-10T02:59:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (20,'27in Monitor',5,349.00,'shipped','2026-06-11T19:33:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (57,1745.00,'paypal',NULL,'2026-06-11T21:22:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (17,'Wireless Mouse',2,29.99,'refunded','2025-04-15T15:02:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (58,59.98,'card','5270-1540-3904-1782','2025-04-15T15:18:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (19,'Mechanical Keyboard',3,129.00,'delivered','2025-03-08T09:20:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (59,387.00,'card','6011-0918-0885-8297','2025-03-08T10:06:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (48,'Mechanical Keyboard',1,129.00,'cancelled','2025-07-30T09:28:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (60,129.00,'paypal',NULL,'2025-07-30T11:18:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (5,'Noise-Cancelling Headset',1,249.00,'delivered','2026-05-31T01:40:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (61,249.00,'card','3477-797853-18875','2026-05-31T02:03:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (6,'Noise-Cancelling Headset',1,249.00,'delivered','2025-04-04T13:06:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (62,249.00,'card','4307-5045-5085-9972','2025-04-04T13:30:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (16,'Wireless Mouse',5,29.99,'delivered','2025-08-11T00:38:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (63,149.95,'card','5497-8746-3014-5529','2025-08-11T00:43:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (46,'Webcam HD',1,79.00,'delivered','2026-05-19T05:11:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (64,79.00,'bank_transfer',NULL,'2026-05-19T05:39:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (36,'Endpoint Agent (1yr)',2,59.00,'shipped','2025-09-09T09:29:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (65,118.00,'card','5106-4523-8560-7861','2025-09-09T10:53:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (1,'Smartphone X',1,999.00,'delivered','2026-05-11T06:02:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (66,999.00,'paypal',NULL,'2026-05-11T08:02:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (36,'Noise-Cancelling Headset',5,249.00,'shipped','2025-11-04T09:23:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (67,1245.00,'bank_transfer',NULL,'2025-11-04T10:05:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (47,'Firewall Appliance',2,2499.00,'shipped','2026-02-10T10:33:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (68,4998.00,'card','5214-8311-4534-2381','2026-02-10T11:25:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (25,'USB-C Dock',1,189.00,'shipped','2025-11-27T19:58:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (69,189.00,'card','3412-681493-28149','2025-11-27T20:20:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'External SSD 2TB',3,159.00,'cancelled','2026-06-10T22:59:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (70,477.00,'bank_transfer',NULL,'2026-06-10T23:23:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (15,'27in Monitor',2,349.00,'refunded','2025-09-04T17:55:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (71,698.00,'card','5496-4364-8861-0979','2025-09-04T18:45:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (40,'Wireless Mouse',3,29.99,'delivered','2025-01-07T02:10:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (72,89.97,'card','4706-1774-1165-9803','2025-01-07T03:04:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (22,'Noise-Cancelling Headset',1,249.00,'shipped','2026-07-19T11:02:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (73,249.00,'bank_transfer',NULL,'2026-07-19T11:34:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (7,'VPN License (1yr)',2,99.00,'delivered','2026-02-19T03:31:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (74,198.00,'bank_transfer',NULL,'2026-02-19T03:33:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (15,'VPN License (1yr)',1,99.00,'delivered','2025-04-27T04:44:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (75,99.00,'card','5496-4364-8861-0979','2025-04-27T04:54:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (4,'Smartphone X',2,999.00,'pending','2025-06-30T09:56:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (25,'External SSD 2TB',1,159.00,'delivered','2025-05-07T13:36:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (77,159.00,'card','3412-681493-28149','2025-05-07T15:05:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (18,'Smartphone X',3,999.00,'refunded','2025-04-09T03:05:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (78,2997.00,'bank_transfer',NULL,'2025-04-09T03:15:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (1,'27in Monitor',3,349.00,'refunded','2025-01-08T13:50:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (79,1047.00,'card','5105-7005-3982-7004','2025-01-08T14:35:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (22,'Smartphone X',1,999.00,'delivered','2025-02-15T02:56:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (80,999.00,'paypal',NULL,'2025-02-15T04:18:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (26,'Firewall Appliance',3,2499.00,'shipped','2025-01-08T08:23:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (81,7497.00,'card','5519-0760-4224-6820','2025-01-08T09:30:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (33,'Wireless Mouse',2,29.99,'delivered','2025-02-11T08:24:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (82,59.98,'paypal',NULL,'2025-02-11T09:14:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (42,'Wireless Mouse',1,29.99,'refunded','2025-07-29T20:48:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (83,29.99,'paypal',NULL,'2025-07-29T21:45:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (42,'27in Monitor',1,349.00,'refunded','2026-07-14T18:28:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (84,349.00,'paypal',NULL,'2026-07-14T19:58:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (4,'Mechanical Keyboard',1,129.00,'delivered','2026-05-11T22:20:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (85,129.00,'paypal',NULL,'2026-05-11T23:53:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (22,'Firewall Appliance',1,2499.00,'shipped','2025-09-04T10:05:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (86,2499.00,'card','5160-5267-8764-3476','2025-09-04T10:46:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (3,'Smartphone X',3,999.00,'pending','2026-01-18T22:15:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (37,'VPN License (1yr)',1,99.00,'delivered','2026-02-15T13:05:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (88,99.00,'card','4256-1877-8842-1806','2026-02-15T13:33:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (11,'Noise-Cancelling Headset',1,249.00,'shipped','2025-03-06T23:21:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (89,249.00,'card','4589-0270-3770-8959','2025-03-06T23:41:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (31,'Smartphone X',1,999.00,'delivered','2025-07-31T16:21:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (90,999.00,'card','4195-6519-5714-0061','2025-07-31T17:47:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (20,'Firewall Appliance',3,2499.00,'delivered','2025-12-03T09:34:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (91,7497.00,'card','4872-1255-1186-6214','2025-12-03T10:25:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (14,'Mechanical Keyboard',1,129.00,'cancelled','2025-08-04T22:14:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (92,129.00,'bank_transfer',NULL,'2025-08-04T23:24:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (5,'Laptop Pro 14',2,1899.00,'delivered','2026-07-03T11:43:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (93,3798.00,'card','3477-797853-18875','2026-07-03T11:59:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (40,'VPN License (1yr)',1,99.00,'delivered','2026-06-12T02:53:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (94,99.00,'card','4706-1774-1165-9803','2026-06-12T04:23:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (25,'Webcam HD',1,79.00,'refunded','2025-06-29T08:05:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (95,79.00,'card','3412-681493-28149','2025-06-29T08:45:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (12,'Endpoint Agent (1yr)',2,59.00,'delivered','2025-07-13T13:45:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (96,118.00,'card','4269-8484-2796-5702','2025-07-13T13:52:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (13,'Noise-Cancelling Headset',1,249.00,'shipped','2025-03-21T08:46:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (97,249.00,'paypal',NULL,'2025-03-21T09:31:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (21,'Mechanical Keyboard',1,129.00,'shipped','2026-06-26T20:14:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (98,129.00,'card','4860-6172-3004-0489','2026-06-26T21:04:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (39,'Mechanical Keyboard',1,129.00,'shipped','2025-07-12T14:17:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (99,129.00,'paypal',NULL,'2025-07-12T14:43:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (40,'Smartphone X',1,999.00,'delivered','2025-10-31T12:08:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (100,999.00,'card','4706-1774-1165-9803','2025-10-31T12:13:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (3,'Laptop Pro 14',1,1899.00,'delivered','2025-06-24T09:16:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (101,1899.00,'card','3462-544485-36561','2025-06-24T10:00:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (16,'Endpoint Agent (1yr)',1,59.00,'pending','2026-06-23T14:14:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (23,'Mechanical Keyboard',2,129.00,'delivered','2025-03-03T14:04:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (103,258.00,'bank_transfer',NULL,'2025-03-03T15:26:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (40,'Endpoint Agent (1yr)',1,59.00,'delivered','2025-11-18T12:44:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (104,59.00,'card','4706-1774-1165-9803','2025-11-18T13:33:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (27,'Webcam HD',3,79.00,'shipped','2025-05-09T19:19:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (105,237.00,'bank_transfer',NULL,'2025-05-09T20:15:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (7,'Webcam HD',1,79.00,'pending','2025-10-30T21:47:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (27,'Noise-Cancelling Headset',1,249.00,'delivered','2025-06-22T08:55:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (107,249.00,'card','3449-585471-81531','2025-06-22T09:46:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (4,'Endpoint Agent (1yr)',1,59.00,'refunded','2025-04-07T05:15:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (108,59.00,'bank_transfer',NULL,'2025-04-07T05:17:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (23,'External SSD 2TB',1,159.00,'delivered','2026-03-31T12:21:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (109,159.00,'card','6011-5343-0104-1630','2026-03-31T14:00:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (34,'Noise-Cancelling Headset',5,249.00,'delivered','2026-07-11T11:15:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (110,1245.00,'card','5421-8281-6894-2500','2026-07-11T11:33:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (50,'VPN License (1yr)',2,99.00,'cancelled','2025-09-14T14:24:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (111,198.00,'card','6011-0965-1197-3119','2025-09-14T14:37:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (9,'USB-C Dock',1,189.00,'delivered','2026-05-01T10:34:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (112,189.00,'card','4045-7759-8618-9955','2026-05-01T12:15:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (49,'Laptop Pro 14',3,1899.00,'delivered','2025-05-13T02:30:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (113,5697.00,'card','4372-4048-4440-6989','2025-05-13T02:56:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (19,'Laptop Pro 14',3,1899.00,'refunded','2026-01-02T05:56:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (114,5697.00,'card','6011-0918-0885-8297','2026-01-02T07:30:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (32,'Mechanical Keyboard',3,129.00,'delivered','2025-05-11T05:13:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (115,387.00,'card','5152-5106-8612-7468','2025-05-11T07:10:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (25,'USB-C Dock',3,189.00,'shipped','2025-09-18T15:09:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (116,567.00,'bank_transfer',NULL,'2025-09-18T16:40:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (21,'Wireless Mouse',1,29.99,'cancelled','2026-06-24T01:38:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (117,29.99,'card','4860-6172-3004-0489','2026-06-24T02:14:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (24,'VPN License (1yr)',5,99.00,'pending','2025-01-24T07:45:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (37,'VPN License (1yr)',2,99.00,'delivered','2025-06-14T04:33:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (119,198.00,'card','4256-1877-8842-1806','2025-06-14T06:09:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (20,'Wireless Mouse',2,29.99,'cancelled','2025-03-05T04:34:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (120,59.98,'card','4872-1255-1186-6214','2025-03-05T06:29:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (40,'27in Monitor',1,349.00,'delivered','2026-06-18T10:11:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (121,349.00,'card','4706-1774-1165-9803','2026-06-18T11:22:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (15,'Mechanical Keyboard',3,129.00,'shipped','2026-08-23T09:54:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (122,387.00,'card','5496-4364-8861-0979','2026-08-23T11:45:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (48,'Mechanical Keyboard',5,129.00,'shipped','2026-08-02T19:19:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (123,645.00,'card','4736-5029-0228-0781','2026-08-02T19:48:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (7,'USB-C Dock',1,189.00,'refunded','2026-04-25T10:14:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (124,189.00,'bank_transfer',NULL,'2026-04-25T12:07:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (27,'Webcam HD',2,79.00,'shipped','2025-09-10T06:22:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (125,158.00,'card','3449-585471-81531','2025-09-10T08:02:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (43,'Noise-Cancelling Headset',5,249.00,'delivered','2025-05-18T23:50:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (126,1245.00,'bank_transfer',NULL,'2025-05-19T01:00:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (26,'Endpoint Agent (1yr)',5,59.00,'delivered','2026-01-22T03:28:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (127,295.00,'paypal',NULL,'2026-01-22T04:56:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (40,'Webcam HD',2,79.00,'delivered','2026-03-11T00:59:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (128,158.00,'card','4706-1774-1165-9803','2026-03-11T01:08:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (36,'External SSD 2TB',2,159.00,'delivered','2026-01-27T19:53:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (129,318.00,'card','5106-4523-8560-7861','2026-01-27T21:12:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (25,'Smartphone X',2,999.00,'refunded','2025-01-14T14:36:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (130,1998.00,'card','3412-681493-28149','2025-01-14T15:36:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (50,'Noise-Cancelling Headset',2,249.00,'pending','2025-09-17T06:39:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (31,'External SSD 2TB',1,159.00,'refunded','2026-04-14T09:36:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (132,159.00,'paypal',NULL,'2026-04-14T09:53:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (39,'Endpoint Agent (1yr)',5,59.00,'pending','2025-11-10T16:15:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (41,'VPN License (1yr)',1,99.00,'delivered','2025-10-03T14:23:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (134,99.00,'card','3745-384864-75095','2025-10-03T15:54:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (45,'27in Monitor',1,349.00,'pending','2025-12-15T11:13:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (30,'External SSD 2TB',5,159.00,'delivered','2025-12-19T05:08:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (136,795.00,'card','5158-1337-0947-1088','2025-12-19T06:14:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (19,'Endpoint Agent (1yr)',2,59.00,'cancelled','2025-02-01T11:04:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (137,118.00,'card','6011-0918-0885-8297','2025-02-01T11:31:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (36,'Webcam HD',3,79.00,'delivered','2026-08-22T18:16:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (138,237.00,'bank_transfer',NULL,'2026-08-22T18:17:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (17,'USB-C Dock',2,189.00,'refunded','2026-05-04T05:26:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (139,378.00,'paypal',NULL,'2026-05-04T07:23:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (2,'Webcam HD',2,79.00,'delivered','2025-05-02T15:14:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (140,158.00,'bank_transfer',NULL,'2025-05-02T15:38:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (43,'Firewall Appliance',1,2499.00,'shipped','2025-03-12T07:56:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (141,2499.00,'bank_transfer',NULL,'2025-03-12T09:55:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (43,'Endpoint Agent (1yr)',1,59.00,'cancelled','2025-10-02T07:37:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (142,59.00,'bank_transfer',NULL,'2025-10-02T08:10:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (25,'Laptop Pro 14',2,1899.00,'delivered','2025-02-10T18:42:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (143,3798.00,'card','3412-681493-28149','2025-02-10T19:49:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (37,'27in Monitor',1,349.00,'shipped','2026-02-02T12:21:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (144,349.00,'card','4256-1877-8842-1806','2026-02-02T14:13:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (40,'Firewall Appliance',5,2499.00,'cancelled','2026-08-05T02:22:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (145,12495.00,'card','4706-1774-1165-9803','2026-08-05T02:26:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (43,'Mechanical Keyboard',1,129.00,'shipped','2025-12-09T02:19:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (146,129.00,'card','4508-8207-1646-3575','2025-12-09T04:05:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'Noise-Cancelling Headset',1,249.00,'delivered','2025-06-13T21:22:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (147,249.00,'card','6011-4319-9093-3021','2025-06-13T23:17:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (29,'Noise-Cancelling Headset',1,249.00,'delivered','2025-07-18T01:29:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (148,249.00,'card','6011-4319-9093-3021','2025-07-18T03:07:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (31,'Endpoint Agent (1yr)',3,59.00,'pending','2025-12-07T13:14:00+08');
INSERT INTO orders (customer_id,product,quantity,unit_price,status,ordered_at) VALUES (45,'Webcam HD',1,79.00,'shipped','2025-11-29T00:15:00+08');
INSERT INTO payments (order_id,amount,method,card_number,paid_at) VALUES (150,79.00,'card','5592-0328-0404-5769','2025-11-29T02:02:00+08');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Steven Young','syoung@acme-demo.example','Finance','Financial Analyst',89500.00,'830-68-6671','007250318','85984086149','2019-09-30');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('David Miller','dmiller@acme-demo.example','Engineering','Engineering Manager',175000.00,'027-31-9007','207538038','041885401264','2024-08-05');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Paul Davis','pdavis@acme-demo.example','Finance','Controller',88500.00,'263-97-1970','363030043','1926259352','2023-05-16');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Sarah Harris','sharris@acme-demo.example','Engineering','Software Engineer',209500.00,'767-20-3156','341110427','67766906798','2023-05-02');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Barbara Carter','bcarter@acme-demo.example','Support','Support Engineer',90000.00,'405-48-2623','222778536','317502677932','2024-03-10');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Nancy Scott','nscott@acme-demo.example','Finance','Controller',132500.00,'179-15-2622','154242282','098694856425','2016-02-17');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Daniel Harris','dharris@acme-demo.example','Engineering','Software Engineer',169500.00,'775-35-8008','024320856','509385691645','2022-02-14');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Rebecca Miller','rmiller@acme-demo.example','Security','Security Analyst',145500.00,'354-28-4947','141358036','5332694952','2023-05-23');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Deborah Hall','dhall@acme-demo.example','Support','Support Engineer',72000.00,'256-29-1655','085610244','6279813044','2023-08-26');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Timothy Hill','thill@acme-demo.example','Support','Support Lead',67500.00,'856-46-1372','172173665','1883270102','2021-12-22');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Stephanie White','swhite@acme-demo.example','HR','HR Manager',125000.00,'043-54-8928','334759841','209300480842','2018-05-13');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Daniel Nguyen','dnguyen@acme-demo.example','Sales','Sales Manager',126000.00,'861-96-4825','325412617','244151109507','2019-02-04');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Kimberly Hill','khill@acme-demo.example','Sales','Account Executive',72500.00,'360-25-0754','079622428','89128089107','2025-03-14');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Carol Mitchell','cmitchell@acme-demo.example','HR','HR Generalist',96500.00,'469-02-9748','369701886','83381917819','2023-10-18');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Betty Hill','bhill@acme-demo.example','Security','Security Analyst',180000.00,'099-45-3088','271421282','93112728465','2015-10-02');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Betty Wilson','bwilson@acme-demo.example','Sales','Account Executive',132000.00,'337-34-2576','392135780','79869310474','2017-03-16');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Matthew Mitchell','mmitchell@acme-demo.example','Finance','Controller',101500.00,'669-82-9332','340239501','86936202789','2023-07-27');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('George Thomas','gthomas@acme-demo.example','Engineering','Engineering Manager',151500.00,'227-53-8118','300196192','98155342839','2016-10-26');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Nancy Green','ngreen@acme-demo.example','Sales','Sales Manager',89000.00,'093-29-7639','291571533','1200493145','2019-11-27');
INSERT INTO employees (full_name,email,department,title,salary_usd,ssn,bank_routing_number,bank_account_number,hired_on) VALUES ('Emily Ramirez','eramirez@acme-demo.example','Support','Support Engineer',57500.00,'251-12-8747','216736274','2054151456','2019-12-12');

ANALYZE;
