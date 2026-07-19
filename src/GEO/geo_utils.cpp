#include "./geo_utils.h"


#include <bits/stdc++.h>
using namespace std;

constexpr double MIN_LONGITUDE = -180.0;
constexpr double MAX_LONGITUDE = 180.0;

constexpr double MIN_LATITUDE = -85.05112878;
constexpr double MAX_LATITUDE = 85.05112878;

constexpr uint32_t GEO_STEP = 26;
constexpr uint32_t SCALE = 1u << GEO_STEP;

constexpr double DEG_TO_RAD = M_PI / 180.0;
constexpr double EARTH_RADIUS_METERS = 6372797.560856;

inline double degToRad(double angle) {
    return angle * DEG_TO_RAD;
}

uint32_t compact(uint64_t value) {
    value &= 0x5555555555555555ULL;

    value = (value | (value >> 1))  & 0x3333333333333333ULL;
    value = (value | (value >> 2))  & 0x0F0F0F0F0F0F0F0FULL;
    value = (value | (value >> 4))  & 0x00FF00FF00FF00FFULL;
    value = (value | (value >> 8))  & 0x0000FFFF0000FFFFULL;
    value = (value | (value >> 16)) & 0x00000000FFFFFFFFULL;

    return static_cast<uint32_t>(value);
}

uint32_t normalize(double value, double minimum, double maximum) {
    return static_cast<uint32_t>(((value - minimum) / (maximum - minimum)) * SCALE);
}

double denormalize(uint32_t grid, double minimum, double maximum) {
    double gridMin = minimum + (maximum - minimum) * (static_cast<double>(grid) / SCALE);
    double gridMax = minimum + (maximum - minimum) * (static_cast<double>(grid + 1) / SCALE);

    return (gridMin + gridMax) / 2;
}

uint64_t interleave(uint32_t lon, uint32_t lat) {
    static const uint64_t B[] = {0x5555555555555555ULL,
                                0x3333333333333333ULL,
                                0x0F0F0F0F0F0F0F0FULL,
                                0x00FF00FF00FF00FFULL,
                                0x0000FFFF0000FFFFULL};

    uint64_t x = lat;
    uint64_t y = lon;

    x = (x | (x << 16)) & B[4];
    y = (y | (y << 16)) & B[4];

    x = (x | (x << 8)) & B[3];
    y = (y | (y << 8)) & B[3];

    x = (x | (x << 4)) & B[2];
    y = (y | (y << 4)) & B[2];

    x = (x | (x << 2)) & B[1];
    y = (y | (y << 2)) & B[1];

    x = (x | (x << 1)) & B[0];
    y = (y | (y << 1)) & B[0];

    return x | (y << 1);
}

void deinterleave(uint64_t score, uint32_t &lon, uint32_t &lat) {
    lon = compact(score >> 1);
    lat = compact(score);
}

uint64_t calculateGeoScore(double longitude, double latitude) {
    uint32_t lon = normalize(longitude, MIN_LONGITUDE, MAX_LONGITUDE);
    uint32_t lat = normalize(latitude, MIN_LATITUDE, MAX_LATITUDE);

    return interleave(lon, lat);
}

pair<double, double> decodeGeoScore(uint64_t score) {
    uint32_t lonGrid, latGrid;

    deinterleave(score, lonGrid, latGrid);

    double lon = denormalize(lonGrid, MIN_LONGITUDE, MAX_LONGITUDE);
    double lat = denormalize(latGrid, MIN_LATITUDE, MAX_LATITUDE);

    return {lon, lat};
}

double getLatitudeDistance(double lat1d, double lat2) {
    return EARTH_RADIUS_METERS * fabs(degToRad(lat2) - degToRad(lat1d));
}

double getGeoDistance(double lon1, double lat1, double lon2, double lat2) {
    double lat1r, lon1r, lat2r, lon2r, u, v, a;
    lon1r = degToRad(lon1);
    lon2r = degToRad(lon2);
    v = sin((lon2r - lon1r) / 2);
    /* if v == 0 we can avoid doing expensive math when lons are practically the same */
    if (v == 0.0)
        return getLatitudeDistance(lat1, lat2);
    lat1r = degToRad(lat1);
    lat2r = degToRad(lat2);
    u = sin((lat2r - lat1r) / 2);
    a = u * u + cos(lat1r) * cos(lat2r) * v * v;
    return 2.0 * EARTH_RADIUS_METERS * asin(sqrt(a));
}
