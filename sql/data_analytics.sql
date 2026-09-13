/*
=============================================================
Create Database and Schemas
=============================================================
Script Purpose:
    This script creates a new database named 'DataWarehouseAnalytics' after checking if it already exists. 
    If the database exists, it is dropped and recreated. Additionally, this script creates a schema called gold
	
WARNING:
    Running this script will drop the entire 'DataWarehouseAnalytics' database if it exists. 
    All data in the database will be permanently deleted. Proceed with caution 
    and ensure you have proper backups before running this script.
*/

USE master;
GO

-- Drop and recreate the 'DataWarehouseAnalytics' database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouseAnalytics')
BEGIN
    ALTER DATABASE DataWarehouseAnalytics SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DataWarehouseAnalytics;
END;
GO

-- Create the 'DataWarehouseAnalytics' database
CREATE DATABASE DataWarehouseAnalytics;
GO

USE DataWarehouseAnalytics;
GO

-- Create Schemas

CREATE SCHEMA gold;
GO

CREATE TABLE gold.dim_customers(
	customer_key int,
	customer_id int,
	customer_number nvarchar(50),
	first_name nvarchar(50),
	last_name nvarchar(50),
	country nvarchar(50),
	marital_status nvarchar(50),
	gender nvarchar(50),
	birthdate date,
	create_date date
);
GO

CREATE TABLE gold.dim_products(
	product_key int ,
	product_id int ,
	product_number nvarchar(50) ,
	product_name nvarchar(50) ,
	category_id nvarchar(50) ,
	category nvarchar(50) ,
	subcategory nvarchar(50) ,
	maintenance nvarchar(50) ,
	cost int,
	product_line nvarchar(50),
	start_date date 
);
GO

CREATE TABLE gold.fact_sales(
	order_number nvarchar(50),
	product_key int,
	customer_key int,
	order_date date,
	shipping_date date,
	due_date date,
	sales_amount int,
	quantity tinyint,
	price int 
);
GO

TRUNCATE TABLE gold.dim_customers;
GO

BULK INSERT gold.dim_customers
FROM -- [ Use Your Path of gold.dim_customers ]
WITH (
	FIRSTROW = 2,
	FIELDTERMINATOR = ',',
	TABLOCK
);
GO

TRUNCATE TABLE gold.dim_products;
GO

BULK INSERT gold.dim_products
FROM -- [ Use Your Path of gold.dim_products ]
WITH (
	FIRSTROW = 2,
	FIELDTERMINATOR = ',',
	TABLOCK
);
GO

TRUNCATE TABLE gold.fact_sales;
GO

BULK INSERT gold.fact_sales
FROM -- [ Use Your Path of gold.fact_sales ]
WITH (
	FIRSTROW = 2,
	FIELDTERMINATOR = ',',
	TABLOCK
);
GO

-- Analyze Trends Over Time From "fact" Table
--		Analyze Sales Performance Over Time

SELECT 
FORMAT(order_date,'yyyy-MM') AS order_date,
SUM(sales_amount) AS total_sales,
COUNT(DISTINCT customer_key) AS total_customers,
SUM(quantity) AS total_quantity
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY FORMAT(order_date,'yyyy-MM')
ORDER BY FORMAT(order_date,'yyyy-MM')

--		Analyze Cumulative Sales Over Time
--			Calculate The Total Sales Per Month & The Running Of Total Sales Over Time & The Moving Average
--			

SELECT 
order_date,
total_sales,
SUM(total_sales) OVER(PARTITION BY order_date ORDER BY order_date) AS running_total_sales,
AVG(avg_price) OVER(PARTITION BY order_date ORDER BY order_date) AS moving_average_price
FROM
(
SELECT 
DATETRUNC(MONTH,order_date) AS order_date,
SUM(sales_amount) AS total_sales,
AVG(price) AS avg_price
FROM gold.fact_sales
WHERE order_date IS NOT NULL
GROUP BY DATETRUNC(MONTH,order_date)
)t

/*Analyze The Yearly Performance Of Products By Comparing Their Sales 
To Both The Average Sales Performance Of The Product And The Previous Year's Sales*/\

WITH yearly_product_sales AS (
SELECT
YEAR(f.order_date) AS order_year,
p.product_name,
SUM(f.sales_amount) AS current_sales
FROM gold.fact_sales f
LEFT JOIN gold.dim_products p
ON f.product_key = p.product_key
WHERE f.order_date IS NOT NULL
GROUP BY
YEAR(f.order_date),
p.product_name
)
SELECT
order_year,
product_name,
current_sales,
AVG(current_sales) OVER(PARTITION BY product_name) AS avg_sales,
current_sales - AVG(current_sales) OVER(PARTITION BY product_name) AS diff_avg,
CASE WHEN current_sales - AVG(current_sales) OVER(PARTITION BY product_name) > 0 THEN 'Above Avg'
	 WHEN current_sales - AVG(current_sales) OVER(PARTITION BY product_name) < 0 THEN 'Below Avg'
	 ELSE 'Avg'
END avg_change,
-- Year-Over-Year Analysis
LAG(current_sales) OVER(PARTITION BY product_name ORDER BY order_year) AS py_sales,
current_sales - LAG(current_sales) OVER(PARTITION BY product_name ORDER BY order_year) AS diff_py,
CASE WHEN current_sales - LAG(current_sales) OVER(PARTITION BY product_name ORDER BY order_year) > 0 THEN 'Increase'
	 WHEN current_sales - LAG(current_sales) OVER(PARTITION BY product_name ORDER BY order_year) < 0 THEN 'Decrease'
	 ELSE 'No Change'
END py_change
FROM yearly_product_sales
ORDER BY product_name, order_year

-- Which Categories Contribute The Most To Overall Sales

WITH category_sales AS (
SELECT
category,
SUM(sales_amount) AS total_sales
FROM gold.fact_sales f
LEFT JOIN gold.dim_products p
ON p.product_key = f.product_key
GROUP BY category
)
SELECT
category,
total_sales,
SUM(total_sales) OVER() AS overall_sales,
ROUND((CAST(total_sales AS FLOAT) / SUM(total_sales) OVER())*100,2) AS percentage_of_total  
FROM category_sales
ORDER BY percentage_of_total DESC

/*Segment Prooducts Into Cost Ranges And
Count How Many Products Fall Into Each Segement*/

WITH product_segments AS (
SELECT
product_key,
product_name,
cost,
CASE WHEN cost < 100 THEN 'Below 100'
	 WHEN cost BETWEEN 100 AND 500 THEN '100-500'
	 WHEN cost BETWEEN 500 AND 1000 THEN '500-1000'
	 ELSE 'Above 1000'
END cost_range
FROM gold.dim_products
)
SELECT
cost_range,
COUNT(product_key) AS total_products
FROM product_segments
GROUP BY cost_range
ORDER BY total_products DESC

/*
Group Customers Into Three Segments Based On Their Spending Behavior:
	    1-VIP: Customers With At Least 12 Months Of History And Spending More Than 5,000.
		2-Regular: Customers With At Least 12 Months Of History But Spending 5,000 Or Less.
		3-New: Customers With Lifespan Less Than 12 Months.
And Find The Total Number Of Customers By Each Group	
*/

WITH customer_spending AS (
SELECT
c.customer_key,
SUM(f.sales_amount) AS total_spending,
MIN(order_date) AS first_order,
MAX(order_date) AS last_order,
DATEDIFF(MONTH,MIN(order_date),MAX(order_date)) AS lifespan
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
ON f.customer_key = c.customer_key
GROUP BY c.customer_key
)
SELECT 
customer_segment,
COUNT(customer_key) AS total_customers
FROM(
SELECT
customer_key,
total_spending,
lifespan,
CASE WHEN lifespan >= 12 AND total_spending > 5000 THEN 'VIP' 
	 WHEN lifespan >= 12 AND total_spending <= 5000 THEN 'Regular'
	 ELSE 'New'
END customer_segment
FROM customer_spending
) t
GROUP BY customer_segment
ORDER BY total_customers DESC

/*
============================================================================
						Customer Report
============================================================================
Purpose:
		This Report Consolidate Key Customer Metrics And Behavior.

Highlights:
		   1- Gathers Essentialn Fields Such AS Names , Ages , And Transaction Details.
		   2- Segments Customers Into Categories (VIP , Regular , New) And Age Groups.
		   3- Aggregate Customer-level Metrics:
					- Total Orders
					- Total Sales
					- Total Quantity Purchased
					- Total Products
					- Lifespan (In Months)
		   4- Calculates Valuable KPIs:
					- Recency (Months Since Last Order)
					- Average Order Value (AOV)
					- Average Monthly Spend
*/

CREATE VIEW gold.report_customers AS

WITH base_query AS (
/*
---------------------------------------------------
Base Query: Retrieves Core Columns From Tables
---------------------------------------------------
*/
SELECT
f.order_number,
f.product_key,
f.order_date,
f.sales_amount,
f.quantity,
c.customer_key,
c.customer_number,
CONCAT(c.first_name, ' ' ,c.last_name) AS customer_name,
DATEDIFF(year, c.birthdate, GETDATE()) age
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
ON c.customer_key = f.customer_key
WHERE order_date IS NOT NULL 
),
customer_aggregation AS (
/*
-----------------------------------------------------------------------
Customers Aggregations: Summarize Key Metrics At The Customer Level
-----------------------------------------------------------------------
*/
SELECT 
customer_key,
customer_number,
customer_name,
age,
COUNT(DISTINCT order_number) AS total_orders,
SUM(sales_amount) AS total_sales,
SUM(quantity) AS total_quantity,
COUNT(DISTINCT product_key) AS total_products,
MAX(order_date) AS last_order_date,
DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan
FROM base_query
GROUP BY customer_key,customer_number,customer_name,age
)
SELECT
customer_key,
customer_number,
customer_name,
age,
CASE WHEN age < 20 THEN 'Under 20'
	 WHEN age BETWEEN 20 AND 29 THEN '20-29'
	 WHEN age BETWEEN 30 AND 39 THEN '30-39'
	 WHEN age BETWEEN 40 AND 49 THEN '40-49'
	 ELSE 'Above 50'
END age_group,
CASE WHEN lifespan >= 12 AND total_sales > 5000 THEN 'VIP' 
	 WHEN lifespan >= 12 AND total_sales <= 5000 THEN 'Regular'
	 ELSE 'New'
END customer_segment,
last_order_date,
DATEDIFF(MONTH, last_order_date, GETDATE()) AS recency,
total_orders,
total_sales,
total_quantity,
total_products,
lifespan,
--	Compute Average Order Value (AOV)
CASE WHEN total_orders = 0 THEN 0
	 ELSE total_sales / total_orders
END avg_order_value,
-- Compue Average Monthly Spend
CASE WHEN lifespan = 0 THEN total_sales
	 ELSE total_sales / lifespan
END avg_monthly_spend
FROM customer_aggregation

SELECT * FROM gold.report_customers

/*
============================================================================
						Product Report
============================================================================
Purpose:
		This Report Consolidate Key Product Metrics And Behaviors.

Highlights:
		   1- Gathers Essentialn Fields Such AS Product Name , Category , Subcategory , And Cost.
		   2- Segments Products By Revenue To Identify High-perfomers , Mid-range Or Low-performers.
		   3- Aggregate Product-level Metrics:
					- Total Orders
					- Total Sales
					- Total Quantity Sold
					- Total Customers (Unique)
					- Lifespan (In Months)
		   4- Calculates Valuable KPIs:
					- Recency (Months Since Last Sale)
					- Average Order Revenue (AOR)
					- Average Monthly Revenue
*/

CREATE VIEW gold.report AS 
WITH base_query AS (
/*
-------------------------------------------------------------------------------
1- Base Query: Retrieves Core Columns From 'fact_sales' And 'dim_products'
-------------------------------------------------------------------------------
*/
SELECT
f.order_number,
f.order_date,
f.customer_key,
f.sales_amount,
f.quantity,
p.product_key,
p.product_name,
p.category,
p.subcategory,
p.cost
FROM gold.fact_sales f
LEFT JOIN gold.dim_products p
ON f.product_key = f.product_key
WHERE order_date IS NOT NULL
),
product_aggregations AS (
/*
--------------------------------------------------------------------------
2- Product Aggregations: Summarizes Key Metrics At The Product Level
--------------------------------------------------------------------------
*/
SELECT
product_key,
product_name,
category,
subcategory,
cost,
DATEDIFF(MONTH, MIN(order_date), MAX(order_date)) AS lifespan,
MAX(order_date) AS last_sale_date,
COUNT(DISTINCT order_number) AS total_orders,
COUNT(DISTINCT customer_key) AS total_customers,
SUM(sales_amount) AS total_sales,
SUM(quantity) AS total_quantity,
ROUND(AVG(CAST(sales_amount AS FLOAT) / NULLIF(quantity,0)),1) AS avg_selling_price
FROM base_query
GROUP BY product_key, product_name, category, subcategory, cost
)
/*
------------------------------------------------------------
3- Final Query: Combines All Product Results Into Output
------------------------------------------------------------
*/

SELECT
product_key,
product_name,
category,
subcategory,
cost,
lifespan,
last_sale_date,
DATEDIFF(MONTH, last_sale_date, GETDATE()) AS recency_in_months,
CASE WHEN total_sales > 50000 THEN 'High-Performer'
	 WHEN total_sales >= 10000 THEN 'Mid-Range'
	 ELSE 'Low-Performer'
END product_segment,
total_orders,
total_sales,
total_quantity,
avg_selling_price,
-- Average Order Revenue (AOR)
CASE WHEN total_orders = 0 THEN 0
	 ELSE total_sales / total_orders
END avg_order_revenue,
-- Average Monthly Revenue
CASE WHEN lifespan = 0 THEN total_sales
	 ELSE total_sales / lifespan
END avg_monthly_revenue
FROM product_aggregations

	