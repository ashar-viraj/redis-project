#pragma once

#include <cstdint>
#include <utility>
#include <cmath>

using namespace std;

uint32_t normalize(double value, double minimum, double maximum);
double denormalize(uint32_t grid, double minimum, double maximum);
uint64_t interleave(uint32_t lon, uint32_t lat);
void deinterleave(uint64_t score, uint32_t &lon, uint32_t &lat);
uint64_t calculateGeoScore(double longitude, double latitude);
pair<double, double> decodeGeoScore(uint64_t score);
double getLatitudeDistance(double lat1d, double lat2);
double getGeoDistance(double lon1, double lat1, double lon2, double lat2);