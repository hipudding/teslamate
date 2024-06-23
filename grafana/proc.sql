CREATE OR REPLACE FUNCTION transformLat(x DOUBLE PRECISION, y DOUBLE PRECISION)
RETURNS DOUBLE PRECISION AS '
DECLARE
    ret DOUBLE PRECISION;
BEGIN
    ret := -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x));
    ret := ret + (20.0 * sin(6.0 * x * pi()) + 20.0 * sin(2.0 * x * pi())) * 2.0 / 3.0;
    ret := ret + (20.0 * sin(y * pi()) + 40.0 * sin(y / 3.0 * pi())) * 2.0 / 3.0;
    ret := ret + (160.0 * sin(y / 12.0 * pi()) + 320 * sin(y * pi() / 30.0)) * 2.0 / 3.0;
    RETURN ret;
END;
' LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION transformLon(x DOUBLE PRECISION, y DOUBLE PRECISION)
RETURNS DOUBLE PRECISION AS '
DECLARE
    ret DOUBLE PRECISION;
BEGIN
    ret := 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x));
    ret := ret + (20.0 * sin(6.0 * x * pi()) + 20.0 * sin(2.0 * x * pi())) * 2.0 / 3.0;
    ret := ret + (20.0 * sin(x * pi()) + 40.0 * sin(x / 3.0 * pi())) * 2.0 / 3.0;
    ret := ret + (150.0 * sin(x / 12.0 * pi()) + 300.0 * sin(x / 30.0 * pi())) * 2.0 / 3.0;
    RETURN ret;
END;
' LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION delta(lat DOUBLE PRECISION, lon DOUBLE PRECISION)
RETURNS TABLE (dLat DOUBLE PRECISION, dLon DOUBLE PRECISION) AS '
DECLARE
    a CONSTANT DOUBLE PRECISION := 6378245.0;
    ee CONSTANT DOUBLE PRECISION := 0.00669342162296594323;
    radLat DOUBLE PRECISION;
    magic DOUBLE PRECISION;
    sqrtMagic DOUBLE PRECISION;
BEGIN
    radLat := lat / 180.0 * pi();
    magic := sin(radLat);
    magic := 1 - ee * magic * magic;
    sqrtMagic := sqrt(magic);
    
    dLat := transformLat(lon - 105.0, lat - 35.0);
    dLon := transformLon(lon - 105.0, lat - 35.0);
    
    dLat := (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi());
    dLon := (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * pi());
    
    RETURN QUERY SELECT dLat, dLon;
END;
' LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION wgs84_to_gcj02(wgsLat DOUBLE PRECISION, wgsLon DOUBLE PRECISION)
RETURNS TABLE (gcjLat DOUBLE PRECISION, gcjLon DOUBLE PRECISION) AS '
DECLARE
    dLat DOUBLE PRECISION;
    dLon DOUBLE PRECISION;
BEGIN
    IF wgsLat < 0 OR wgsLat > 60.0 OR wgsLon < 72.004 OR wgsLon > 137.8347 THEN
        RETURN QUERY SELECT wgsLat, wgsLon;
    ELSE
        SELECT delta.dLat, delta.dLon INTO dLat, dLon FROM delta(wgsLat, wgsLon);
        SELECT wgsLat + dLat, wgsLon + dLon INTO gcjLat, gcjLon;
        RETURN QUERY SELECT gcjLat, gcjLon;
    END IF;
END;
' LANGUAGE plpgsql;

