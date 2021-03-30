USE [AdventureWorks2017]
GO

----------------------------------------------------- SCHEMA -----------------------------------------------------

-- Create Schema if it doesn't exists
IF (SCHEMA_ID('Auction') IS NULL) 
BEGIN
    EXEC ('CREATE SCHEMA [Auction]')
END

----------------------------------------------------- Configuration Table -----------------------------------------------------

-- 
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = N'Configuration')
BEGIN
    CREATE TABLE Auction.Configuration
	(
		MakeFlag0 decimal(5,2),
		MakeFlag1 decimal(5,2),
		MinIncreaseBid money NOT NULL,
		MaxIncreaseBid decimal NOT NULL,
		StartBidDate datetime NOT NULL, -- SET to 16th November of 2020
		StopBidDate datetime NOT NULL   -- SET to 29th November of 2020
	);

	INSERT INTO Auction.Configuration
           ([MakeFlag0]
		   ,[MakeFlag1]
		   ,[MinIncreaseBid]
           ,[MaxIncreaseBid]
           ,[StartBidDate]
           ,[StopBidDate])
		VALUES
           (0.75
		   ,0.5
		   ,0.05
           ,1
           ,'2020-11-16 00:00:00:000'
           ,'2020-11-29 00:00:00:000');
END

-- Check Configuration table
SELECT * FROM Auction.Configuration

GO

----------------------------------------------------- Auction Products Table -----------------------------------------------------

IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = N'Products')
BEGIN
    CREATE TABLE Auction.Products
	(
		ProductID int PRIMARY KEY NOT NULL REFERENCES Production.Product(ProductID),
		[Name] nvarchar(50) NULL REFERENCES Production.Product(Name),
		ProductCategoryID int NULL REFERENCES Production.ProductCategory(ProductCategoryID),
		InitialBidPrice money NOT NULL,
		InitialDate datetime NOT NULL,
		[ExpireDate] datetime NULL,
		AuctionStatus nvarchar(50) NOT NULL,
		MakeFlag bit NOT NULL
	);
END

-- Check Products table
SELECT * FROM Auction.Products

GO

----------------------------------------------------- Auction ProductsBids Table -----------------------------------------------------

IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = N'ProductsBids')
BEGIN
    CREATE TABLE Auction.ProductsBids
	(
		BidID int IDENTITY(1,1) PRIMARY KEY,
		ProductID int NOT NULL REFERENCES Production.Product(ProductID),
		[Name] nvarchar(50) NULL REFERENCES Production.Product(Name),
		CustomerID int NOT NULL REFERENCES Sales.Customer(CustomerID),
		CurrentPrice money,
		BidAmount money NULL,
		StartTime datetime NULL,
		EndTime datetime NULL,
		BidStatus int NOT NULL,
		AuctionStatus nvarchar(50) NOT NULL --VER
	);
END

-- Check ProductsBids table
SELECT * FROM Auction.ProductsBids

GO
----------------------------------------------------- SP uspAddProductToAuction -----------------------------------------------------

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE Auction.uspAddProductToAuction
(
	@ProductID int,
	@ExpireDate datetime = NULL,
	@InitialBidPrice money = NULL
) 
AS
BEGIN;
DECLARE @Percentage decimal(5,2);
DECLARE @ProductCategoryId int = NULL;
DECLARE @Name nvarchar(50);
DECLARE @MakeFlag bit;
DECLARE @Counter int;
DECLARE @StartBidDate datetime = (SELECT StartBidDate FROM Auction.Configuration);
DECLARE @StopBidDate datetime = (SELECT StopBidDate FROM Auction.Configuration);
DECLARE @InitialDate datetime;
DECLARE @AuctionStatus nvarchar(50);

SET @Name = (SELECT [Name] FROM Production.Product WHERE ProductID = @ProductID);
SET @MakeFlag = (SELECT MakeFlag FROM Production.Product WHERE ProductID = @ProductID);

-- Not possible to use a ProductID that isn't in the company's database
IF (SELECT COUNT(ProductID) FROM Production.Product WHERE ProductID = @ProductID) = 0
	THROW 60000,'Inexistent product.', 1
	
--Only products that are currently commercialized (both SellEndDate and DiscontinuedDate values not set)
IF (SELECT SellEndDate FROM Production.Product WHERE ProductID = @ProductID) IS NOT NULL OR
	(SELECT DiscontinuedDate FROM Production.Product WHERE ProductID = @ProductID) IS NOT NULL
	THROW 60001,'This product is no longer commercialized.', 1

-- Not possible to auction products that aren't available for sale
IF (SELECT SellStartDate FROM Production.Product WHERE ProductID = @ProductID) > @StartBidDate
	THROW 60002,'This product is not yet available for sale.', 1

IF @ExpireDate IS NULL
	BEGIN;
		IF @StartBidDate > GETDATE()
			BEGIN;
				SET @ExpireDate = DATEADD(DAY, 7, @StartBidDate)
			END
		ELSE
			BEGIN;
				IF GETDATE() > (DATEADD(DAY, -7, @StopBidDate))
					BEGIN;
					PRINT 'Date exceeds auction limit. Set to auction end date.'
					SET @ExpireDate = @StopBidDate
					END
			END
	END
ELSE -- ExpireDate can not exceed StopBidDate
	BEGIN;
		IF @ExpireDate > @StopBidDate
			BEGIN;
			PRINT 'Date exceeds auction limit. Setting up Expire Date to auction end date.'
			SET @ExpireDate = CONVERT(DATE, @StopBidDate)
			END
		IF @ExpireDate < GETDATE()
			THROW 60003,'Expire Date should be above present date.', 1
	END

-- Only one item for each ProductID can be simultaneously enlisted as an auctioned.
SET @Counter = (SELECT COUNT(ProductID) FROM Auction.Products WHERE ProductID = @ProductID)
IF @Counter > 0
	THROW 60004,'Product already enlisted in the auction.', 1
		
-- Check category. Category = 4 isn't allowed
IF (SELECT Subc.ProductCategoryID
	FROM Production.Product AS Prod
	LEFT JOIN Production.ProductSubcategory AS Subc
		ON Prod.ProductSubcategoryID = Subc.ProductSubcategoryID
		WHERE ProductID = @ProductID) = 4
	THROW 60005,'Product is an accessory and can not be enlisted for auction.', 1
ELSE
	SET @ProductCategoryId = (SELECT Subc.ProductCategoryID
	FROM Production.Product AS Prod
	LEFT JOIN Production.ProductSubcategory AS Subc
		ON Prod.ProductSubcategoryID = Subc.ProductSubcategoryID
		WHERE ProductID = @ProductID)

-- Only products that cost more than 50$ can be enlisted for online auction campaign.
IF (SELECT StandardCost FROM Production.Product WHERE ProductID = @ProductID) <= 50
	THROW 60006,'Product must cost more than $50 to be enlisted.', 1

-- Set the percentage to be used in the initialbid price: MakeFlag = 1 -> percentage = 0.50 and MakeFlag = 0 -> percentage = 0.75
IF (SELECT MakeFlag FROM Production.Product WHERE ProductID = @ProductID) = 1 
	SET @Percentage = (SELECT MakeFlag1 FROM Auction.Configuration);
ELSE
	SET @Percentage = (SELECT MakeFlag0 FROM Auction.Configuration);

-- If @InitialBidPrice is NULL, define the InitialBidPrice accordingly with MakeFlag
IF @InitialBidPrice IS NULL
	SET @InitialBidPrice = (SELECT ListPrice * @Percentage FROM Production.Product WHERE ProductID = @ProductID);
ELSE
	BEGIN;
		IF @InitialBidPrice < (SELECT ListPrice * @Percentage FROM Production.Product WHERE ProductID = @ProductID)
		THROW 60007,'The InitialBidPrice is not being respected when compared with the Listed Price.', 1
	END

SET @InitialDate = GETDATE();
IF @InitialDate < @StartBidDate
	SET @InitialDate = @StartBidDate;

SET @AuctionStatus = 'Active';

		INSERT INTO Auction.Products
           ([ProductID]
		   ,[Name]
           ,[ProductCategoryID]
           ,[InitialBidPrice]
		   ,[InitialDate]
           ,[ExpireDate]
		   ,AuctionStatus
		   ,[MakeFlag])
		VALUES
           (@ProductId
		   ,@Name
           ,@ProductCategoryId
           ,@InitialBidPrice
		   ,@InitialDate
           ,@ExpireDate
		   ,@AuctionStatus
		   ,@MakeFlag);

SELECT * FROM Auction.Products WHERE ProductID = @ProductID;

END

GO
----------------------------------------------------- SP uspTryBidProduct -----------------------------------------------------

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE Auction.uspTryBidProduct
(
	@ProductID int,
	@CustomerID int,
	@BidAmount money = NULL
)
AS
BEGIN;
DECLARE @StartTime datetime = (GETDATE());
DECLARE @Counter int;
DECLARE @CurrentPrice money;
DECLARE @MinIncreaseBid money = (SELECT MinIncreaseBid FROM Auction.Configuration);
DECLARE @InitialBidPrice money = (SELECT InitialBidPrice FROM Auction.Products WHERE ProductID = @ProductID);
DECLARE @MaxIncreaseBid money = (SELECT MaxIncreaseBid FROM Auction.Configuration);
DECLARE @BidID int;
DECLARE @EndTime datetime;
DECLARE @MaxBid money = (SELECT ListPrice*@MaxIncreaseBid FROM Production.Product WHERE ProductID = @ProductID);
DECLARE @Name nvarchar(50) = (SELECT [Name] FROM Production.Product WHERE ProductID = @ProductID);
DECLARE @CounterBID int;
DECLARE @AuctionEndDate datetime = (SELECT [ExpireDate] FROM Auction.Products WHERE ProductID = @ProductID);
DECLARE @AuctionStatus nvarchar(50) = (SELECT AuctionStatus FROM Auction.Products WHERE ProductID = @ProductID);

BEGIN TRY
	BEGIN TRANSACTION; ----------------------------------------------------------------------------------------------------------------------- TRANSACTION Rita
		SET @Counter = (SELECT ProductID FROM Auction.Products WHERE ProductID = @ProductID)
		IF COUNT(@Counter) = 0 
				THROW 60008,'Product not in auction', 1

		IF @AuctionEndDate < GETDATE()
			OR (SELECT AuctionStatus FROM Auction.ProductsBids WHERE ProductID = @ProductID AND BidStatus = 1) = 'Terminated'
			THROW 60009,'Auction is terminated.', 1

		IF (SELECT AuctionStatus FROM Auction.ProductsBids WHERE ProductID = @ProductID AND BidStatus = 1) = 'Sold'
			THROW 60010,'The product was already sold.', 1
		
		SET @CustomerID = (SELECT CustomerID FROM Sales.Customer WHERE CustomerID = @CustomerID)
		IF @CustomerID IS NULL
				THROW 60011,'Invalid customer.', 1

		ELSE
			BEGIN
			IF @BidAmount IS NULL
				BEGIN
					SET @CounterBID = (SELECT COUNT(ProductID) FROM Auction.ProductsBids WHERE ProductID = @ProductID AND BidStatus = 1)
					IF @CounterBID = 0
						BEGIN
						SET @BidAmount = @InitialBidPrice + @MinIncreaseBid 
						SET @CurrentPrice = @BidAmount
						END
					ELSE
						BEGIN
						SET @CurrentPrice = (SELECT MAX(CurrentPrice) FROM Auction.ProductsBids WHERE ProductID = @ProductID AND BidStatus = 1)
						SET @BidAmount = @CurrentPrice + @MinIncreaseBid
						IF (@BidAmount > @MaxBid)
                            BEGIN;
                                SET @BidAmount = @MaxBid;
								SET @CurrentPrice = @BidAmount;
                                PRINT 'Bid amount exceeds maximum allowed. Your bid was set to the maximum. Congratulations, you won the product auction! '
                                SET @AuctionStatus = 'Sold'; -- PP: Coloca o auction status como terminated se o cliente bater o maximo bid
                                UPDATE Auction.Products SET AuctionStatus = 'Sold' WHERE ProductID = @ProductID
                            END
                        ELSE
							SET @CurrentPrice = @BidAmount
						END
				END
			ELSE
				BEGIN
				SET @CurrentPrice = (SELECT MAX(CurrentPrice) FROM Auction.ProductsBids WHERE ProductID = @ProductID AND AuctionStatus = 'Active')
				IF (@BidAmount < @InitialBidPrice + @MinIncreaseBid) 
					THROW 60012,'Bid amount must be above listed price. Please, check the minimum increase bid.', 1
				IF (@BidAmount < @CurrentPrice + @MinIncreaseBid) 
					THROW 60013,'Bid amount must be above listed price. Please, check the minimum increase bid.', 1
				IF (@BidAmount >= @MaxBid) 
					BEGIN;
						SET @BidAmount = @MaxBid;
						PRINT 'Bid amount exceeds maximum allowed. Your bid was set to the maximum. Congratulations, you won the product auction! '
						SET @AuctionStatus = 'Sold';
						UPDATE Auction.Products SET AuctionStatus = 'Sold' WHERE ProductID = @ProductID
					END
				SET @CurrentPrice = @BidAmount
				END
		END

			SELECT @BidID = BidID FROM Auction.ProductsBids WHERE ProductID = @ProductID AND BidStatus > 0;
			UPDATE Auction.ProductsBids SET BidStatus = 0 WHERE BidID = @BidID;
			UPDATE Auction.ProductsBids SET EndTime = GETDATE() WHERE BidID = @BidID;
			UPDATE Auction.ProductsBids SET CurrentPrice = @CurrentPrice WHERE ProductID = @ProductID AND AuctionStatus = 'Active';
			IF @BidAmount = @MaxBid
				BEGIN;
					UPDATE Auction.ProductsBids SET AuctionStatus = 'Sold' WHERE ProductID = @ProductID;
					SET @EndTime = GETDATE();
				END
               
	COMMIT TRANSACTION;
END TRY
BEGIN CATCH
	IF (@@TRANCOUNT > 0)
		ROLLBACK TRANSACTION;
		THROW;
END CATCH

		INSERT INTO Auction.ProductsBids
			([ProductID]
			,[Name]
			,[CustomerID]
			,[BidAmount]
			,[StartTime]
			,[EndTime]
			,[CurrentPrice]
			,[BidStatus]
			,[AuctionStatus])
		VALUES
			(@ProductID
			,@Name
			,@CustomerID
			,@BidAmount
			,@StartTime
			,@EndTime
			,@CurrentPrice
			,1
			,@AuctionStatus);

END;

GO

----------------------------------------------------- SP uspRemoveProductFromAuction -----------------------------------------------------

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE Auction.uspRemoveProductFromAuction
(
	@ProductID int
) 
AS
BEGIN;
DECLARE @Counter int;

SET @Counter = (SELECT COUNT(ProductID) FROM Auction.Products WHERE ProductID = @ProductID)
IF @Counter = 0
	THROW 60014,'Product not enlisted for auction.', 1


-- Remove product from Auction.Products
DELETE FROM Auction.Products WHERE ProductID = @ProductID;

-- Update to Cancelled status

UPDATE Auction.ProductsBids SET EndTime = GETDATE() WHERE ProductID = @ProductID AND BidStatus = 1;

UPDATE Auction.ProductsBids SET BidStatus = 0 WHERE ProductID = @ProductID;

UPDATE Auction.ProductsBids SET AuctionStatus = 'Cancelled' WHERE ProductID = @ProductID;

END;

GO

----------------------------------------------------- SP uspSearchForAuctionBasedOnProductName -----------------------------------------------------

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE Auction.uspSearchForAuctionBasedOnProductName
(
	@Productname nvarchar(50), 
	@StartingOffSet int = NULL, 
	@NumberOfRows int = NULL
)
AS
BEGIN
DECLARE @Counter INT;

SELECT @Counter = COUNT(Name) 
	FROM Auction.Products
	WHERE [Name] LIKE '%' + @Productname + '%'

IF LEN(@Productname) < 3
	THROW 60015,'Searches are not acceptable if wildcard search contains less than 3 characters.', 1   
IF (@Counter < 1)
    THROW 60016,'Product containing the inserted expression does not exist.',1
ELSE
	IF @StartingOffSet IS NULL
		SET @StartingOffSet = 1;
	IF @NumberOfRows IS NULL
		SET @NumberOfRows = 2000000;
	
	SELECT Auction.Products.[Name], ProductNumber, Color, Size, SizeUnitMeasureCode, WeightUnitMeasureCode, [Weight], Style, ProductSubCategoryID, AuctionStatus, @@ROWCOUNT AS TotalCount
	FROM Auction.Products
	LEFT JOIN Production.Product
	ON Auction.Products.ProductID = Production.Product.ProductID
	WHERE Auction.Products.[Name] LIKE '%' + @Productname + '%'
	ORDER BY Auction.Products.[Name] DESC
	OFFSET (@StartingOffSet - 1) ROWS
	FETCH NEXT @NumberOfRows ROWS ONLY;

END

GO

----------------------------------------------------- SP uspListBidsOffersHistory -----------------------------------------------------

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE Auction.uspListBidsOffersHistory
(
	@CustomerID int,
	@StartTime datetime,
	@EndTime datetime = NULL,
	@Active bit = NULL
)

AS
BEGIN;

DECLARE @Counter int
SET @Counter = (SELECT COUNT(CustomerID) FROM Auction.ProductsBids WHERE CustomerID = @CustomerID)
IF @Counter = 0
	THROW 60017,'Customer does not exist in auction products bids database', 1

IF @StartTime > @EndTime
	THROW 60018,'Please guarantee that the start time does not exceed the end time.', 1  

IF @Endtime IS NULL
	SET @EndTime = GETDATE()

IF @Active = 1 OR @Active = NULL
	SELECT * 
	FROM Auction.ProductsBids
	WHERE CustomerID = @CustomerID 
	AND StartTime BETWEEN @StartTime AND @Endtime
	AND AuctionStatus = 'Active';

ELSE 
	SELECT * 
	FROM Auction.ProductsBids
	WHERE CustomerID = @CustomerID 
	AND StartTime BETWEEN @StartTime AND @Endtime;

IF @@ROWCOUNT = 0
	THROW 60019, 'No bids found.', 1
END;

GO

----------------------------------------------------- SP uspUpdateProductAuctionStatus -----------------------------------------------------

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE Auction.uspUpdateProductAuctionStatus
AS
BEGIN;
-- Rita confirmar se podemos apagar este update porque não temos o codigo preparado para lidar com status Inactive
--meter como active quando auction começa --FUNCIONA
UPDATE Auction.Products SET AuctionStatus = 'Active' WHERE InitialDate < GETDATE() AND [ExpireDate] > GETDATE() AND AuctionStatus = 'Inactive' 
--MUDAR AUCTIONSTATUS DEFAULT PARA INACTIVE

UPDATE Auction.ProductsBids SET AuctionStatus = 'Sold'
	FROM Auction.Products AS Prod LEFT JOIN Auction.ProductsBids ON ProductsBids.ProductID = Prod.ProductID
	WHERE Prod.[ExpireDate] < GETDATE()

UPDATE Auction.Products SET AuctionStatus = 'Sold'
	FROM Auction.Products AS Prod LEFT JOIN Auction.ProductsBids ON ProductsBids.ProductID = Prod.ProductID
	WHERE ProductsBids.BidStatus = 1 AND ProductsBids.AuctionStatus = 'Sold'

UPDATE Auction.Products SET AuctionStatus = 'Terminated'
	WHERE ProductID NOT IN (SELECT ProductID FROM Auction.ProductsBids)
	AND [ExpireDate] < GETDATE()

END;

--SELECT * FROM Auction.Products
--SELECT * FROM Auction.ProductsBids
--SELECT ListPrice * 1 FROM Production.Product WHERE ProductID = 989
--EXECUTE Auction.uspUpdateProductAuctionStatus

SELECT * FROM Auction.ProductsBids
