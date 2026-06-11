-- ============================================================
--  CA Client & Compliance Management System
--  Database: MySQL
-- ============================================================

CREATE DATABASE IF NOT EXISTS ca_management;
USE ca_management;

-- ============================================================
--  TABLE DEFINITIONS
-- ============================================================

CREATE TABLE Client (
    Client_ID     INT AUTO_INCREMENT PRIMARY KEY,
    Name          VARCHAR(100) NOT NULL,
    PAN           VARCHAR(10)  NOT NULL UNIQUE,
    Phone         VARCHAR(15)  NOT NULL,
    Email         VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE Service (
    Service_ID    INT AUTO_INCREMENT PRIMARY KEY,
    Service_Name  VARCHAR(100) NOT NULL,
    Fees          DECIMAL(10,2) NOT NULL
);

CREATE TABLE Regulations (
    Reg_ID        INT AUTO_INCREMENT PRIMARY KEY,
    Name          VARCHAR(100) NOT NULL,
    Description   TEXT
);

CREATE TABLE Compliance (
    Compliance_ID INT AUTO_INCREMENT PRIMARY KEY,
    Type          VARCHAR(100) NOT NULL,
    Status        ENUM('Pending', 'Completed', 'Overdue') DEFAULT 'Pending',
    Due_Date      DATE NOT NULL,
    Reg_ID        INT NOT NULL,
    Client_ID     INT NOT NULL,
    FOREIGN KEY (Reg_ID)   REFERENCES Regulations(Reg_ID) ON DELETE CASCADE,
    FOREIGN KEY (Client_ID) REFERENCES Client(Client_ID)  ON DELETE CASCADE
);

CREATE TABLE Client_Service (
    CS_ID         INT AUTO_INCREMENT PRIMARY KEY,
    Client_ID     INT  NOT NULL,
    Service_ID    INT  NOT NULL,
    Usage_Date    DATE NOT NULL DEFAULT (CURDATE()),
    FOREIGN KEY (Client_ID)  REFERENCES Client(Client_ID)  ON DELETE CASCADE,
    FOREIGN KEY (Service_ID) REFERENCES Service(Service_ID) ON DELETE CASCADE
);

CREATE TABLE Billing (
    Bill_ID        INT AUTO_INCREMENT PRIMARY KEY,
    Client_ID      INT            NOT NULL,
    Amount         DECIMAL(10,2)  NOT NULL,
    Payment_Status ENUM('Paid', 'Unpaid', 'Overdue') DEFAULT 'Unpaid',
    Bill_Date      DATE           NOT NULL DEFAULT (CURDATE()),
    FOREIGN KEY (Client_ID) REFERENCES Client(Client_ID) ON DELETE CASCADE
);

-- ============================================================
--  VIEWS
-- ============================================================

-- All unpaid bills with client details
CREATE VIEW View_Unpaid_Bills AS
SELECT
    b.Bill_ID,
    c.Name        AS Client_Name,
    c.Email,
    b.Amount,
    b.Bill_Date,
    b.Payment_Status
FROM Billing b
JOIN Client c ON b.Client_ID = c.Client_ID
WHERE b.Payment_Status != 'Paid';

-- All compliance records with client and regulation info
CREATE VIEW View_Compliance_Status AS
SELECT
    co.Compliance_ID,
    c.Name          AS Client_Name,
    co.Type,
    co.Status,
    co.Due_Date,
    r.Name          AS Regulation_Name
FROM Compliance co
JOIN Client c      ON co.Client_ID = c.Client_ID
JOIN Regulations r ON co.Reg_ID    = r.Reg_ID;

-- Services availed by each client with fees
CREATE VIEW View_Client_Services AS
SELECT
    c.Client_ID,
    c.Name          AS Client_Name,
    s.Service_Name,
    s.Fees,
    cs.Usage_Date
FROM Client_Service cs
JOIN Client  c ON cs.Client_ID  = c.Client_ID
JOIN Service s ON cs.Service_ID = s.Service_ID;

-- ============================================================
--  STORED PROCEDURES
-- ============================================================

DELIMITER $$

-- 1. Generate a bill for a client based on all services used
CREATE PROCEDURE GenerateBill(IN p_client_id INT)
BEGIN
    DECLARE total_fees DECIMAL(10,2);

    SELECT SUM(s.Fees)
    INTO total_fees
    FROM Client_Service cs
    JOIN Service s ON cs.Service_ID = s.Service_ID
    WHERE cs.Client_ID = p_client_id;

    IF total_fees IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No services found for this client.';
    ELSE
        INSERT INTO Billing (Client_ID, Amount, Payment_Status, Bill_Date)
        VALUES (p_client_id, total_fees, 'Unpaid', CURDATE());
        SELECT CONCAT('Bill generated for Client ID ', p_client_id, '. Amount: ', total_fees) AS Result;
    END IF;
END$$

-- 2. Get full report for a client (services, bills, compliance)
CREATE PROCEDURE GetClientReport(IN p_client_id INT)
BEGIN
    -- Client info
    SELECT * FROM Client WHERE Client_ID = p_client_id;

    -- Services availed
    SELECT s.Service_Name, s.Fees, cs.Usage_Date
    FROM Client_Service cs
    JOIN Service s ON cs.Service_ID = s.Service_ID
    WHERE cs.Client_ID = p_client_id;

    -- Billing history
    SELECT Bill_ID, Amount, Payment_Status, Bill_Date
    FROM Billing
    WHERE Client_ID = p_client_id;

    -- Compliance status
    SELECT co.Type, co.Status, co.Due_Date, r.Name AS Regulation
    FROM Compliance co
    JOIN Regulations r ON co.Reg_ID = r.Reg_ID
    WHERE co.Client_ID = p_client_id;
END$$

-- 3. Mark overdue bills automatically
CREATE PROCEDURE MarkOverdueBills()
BEGIN
    UPDATE Billing
    SET Payment_Status = 'Overdue'
    WHERE Payment_Status = 'Unpaid'
      AND Bill_Date < DATE_SUB(CURDATE(), INTERVAL 30 DAY);

    SELECT ROW_COUNT() AS Bills_Marked_Overdue;
END$$

DELIMITER ;

-- ============================================================
--  TRIGGERS
-- ============================================================

DELIMITER $$

-- 1. Auto-mark compliance as Overdue when Due_Date has passed on INSERT
CREATE TRIGGER trg_compliance_status_insert
BEFORE INSERT ON Compliance
FOR EACH ROW
BEGIN
    IF NEW.Due_Date < CURDATE() AND NEW.Status = 'Pending' THEN
        SET NEW.Status = 'Overdue';
    END IF;
END$$

-- 2. Auto-mark compliance as Overdue on UPDATE too
CREATE TRIGGER trg_compliance_status_update
BEFORE UPDATE ON Compliance
FOR EACH ROW
BEGIN
    IF NEW.Due_Date < CURDATE() AND NEW.Status = 'Pending' THEN
        SET NEW.Status = 'Overdue';
    END IF;
END$$

-- 3. Log billing changes (requires audit table)
CREATE TABLE IF NOT EXISTS Billing_Audit (
    Audit_ID    INT AUTO_INCREMENT PRIMARY KEY,
    Bill_ID     INT,
    Old_Status  VARCHAR(20),
    New_Status  VARCHAR(20),
    Changed_At  DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TRIGGER trg_billing_status_change
AFTER UPDATE ON Billing
FOR EACH ROW
BEGIN
    IF OLD.Payment_Status != NEW.Payment_Status THEN
        INSERT INTO Billing_Audit (Bill_ID, Old_Status, New_Status)
        VALUES (OLD.Bill_ID, OLD.Payment_Status, NEW.Payment_Status);
    END IF;
END$$

DELIMITER ;

-- ============================================================
--  SAMPLE DATA
-- ============================================================

INSERT INTO Client (Name, PAN, Phone, Email) VALUES
('Rajesh Mehta',   'ABCPM1234R', '9876543210', 'rajesh@example.com'),
('Priya Sharma',   'XYZPS5678T', '9123456780', 'priya@example.com'),
('Anand Traders',  'MNOPT9012U', '9988776655', 'anand@example.com');

INSERT INTO Service (Service_Name, Fees) VALUES
('ITR Filing',          2500.00),
('GST Registration',    3000.00),
('GST Return Filing',   1500.00),
('Tax Audit',           8000.00),
('Accounting Services', 5000.00);

INSERT INTO Regulations (Name, Description) VALUES
('Income Tax Act',    'Governs income tax filing and compliance'),
('GST Act',           'Governs GST registration and return filing'),
('Companies Act',     'Governs corporate compliance and filings');

INSERT INTO Client_Service (Client_ID, Service_ID, Usage_Date) VALUES
(1, 1, '2024-04-01'),
(1, 4, '2024-04-01'),
(2, 2, '2024-05-15'),
(2, 3, '2024-06-01'),
(3, 5, '2024-03-10'),
(3, 1, '2024-03-10');

INSERT INTO Compliance (Type, Status, Due_Date, Reg_ID, Client_ID) VALUES
('ITR Filing FY2023-24',     'Completed', '2024-07-31', 1, 1),
('GST Return Q1',            'Pending',   '2025-07-15', 2, 2),
('Annual ROC Filing',        'Overdue',   '2024-12-31', 3, 3),
('Advance Tax Q2',           'Pending',   '2025-09-15', 1, 1);

-- ============================================================
--  SAMPLE QUERIES (for reference / documentation)
-- ============================================================

-- 1. All clients with pending or overdue compliance
SELECT c.Name, co.Type, co.Status, co.Due_Date
FROM Compliance co
JOIN Client c ON co.Client_ID = c.Client_ID
WHERE co.Status IN ('Pending', 'Overdue')
ORDER BY co.Due_Date;

-- 2. Total revenue per service
SELECT s.Service_Name, COUNT(cs.CS_ID) AS Times_Used,
       SUM(s.Fees) AS Total_Revenue
FROM Client_Service cs
JOIN Service s ON cs.Service_ID = s.Service_ID
GROUP BY s.Service_ID, s.Service_Name
ORDER BY Total_Revenue DESC;

-- 3. Clients with unpaid bills
SELECT c.Name, b.Amount, b.Bill_Date, b.Payment_Status
FROM Billing b
JOIN Client c ON b.Client_ID = c.Client_ID
WHERE b.Payment_Status != 'Paid';

-- 4. Nested query: clients who have used more than 1 service
SELECT Name FROM Client
WHERE Client_ID IN (
    SELECT Client_ID FROM Client_Service
    GROUP BY Client_ID
    HAVING COUNT(*) > 1
);

-- 5. Call stored procedures
CALL GenerateBill(2);
CALL GetClientReport(1);
CALL MarkOverdueBills();
