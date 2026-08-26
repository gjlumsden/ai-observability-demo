const WEATHER_TIMEOUT_MS = 20000;

const weatherDescriptions = new Map([
  [0, 'Clear sky'],
  [1, 'Mainly clear'],
  [2, 'Partly cloudy'],
  [3, 'Overcast'],
  [45, 'Fog'],
  [48, 'Rime fog'],
  [51, 'Light drizzle'],
  [53, 'Drizzle'],
  [55, 'Dense drizzle'],
  [61, 'Light rain'],
  [63, 'Rain'],
  [65, 'Heavy rain'],
  [71, 'Light snow'],
  [73, 'Snow'],
  [75, 'Heavy snow'],
  [80, 'Light rain showers'],
  [81, 'Rain showers'],
  [82, 'Heavy rain showers'],
  [85, 'Snow showers'],
  [86, 'Heavy snow showers'],
  [95, 'Thunderstorm'],
  [96, 'Thunderstorm with hail'],
  [99, 'Severe thunderstorm with hail']
]);

async function fetchJson(url) {
  let response;
  try {
    response = await fetch(url, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(WEATHER_TIMEOUT_MS)
    });
  } catch (error) {
    if (error.name === 'TimeoutError') {
      const timeoutError = new Error('The weather service timed out.');
      timeoutError.status = 504;
      throw timeoutError;
    }
    throw error;
  }
  if (!response.ok) {
    throw new Error(`Weather service returned HTTP ${response.status}.`);
  }
  return response.json();
}

async function getWeatherForecast(location, forecastDays) {
  const searchName = location.split(',')[0].trim();
  const geocodeUrl = new URL('https://geocoding-api.open-meteo.com/v1/search');
  geocodeUrl.search = new URLSearchParams({
    name: searchName,
    count: '1',
    language: 'en',
    format: 'json'
  });
  const geocode = await fetchJson(geocodeUrl);
  const place = geocode.results?.[0];
  if (!place) {
    throw new Error('The location was not found.');
  }

  const forecastUrl = new URL('https://api.open-meteo.com/v1/forecast');
  forecastUrl.search = new URLSearchParams({
    latitude: String(place.latitude),
    longitude: String(place.longitude),
    daily: [
      'weather_code',
      'temperature_2m_max',
      'temperature_2m_min',
      'precipitation_probability_max',
      'wind_speed_10m_max'
    ].join(','),
    timezone: 'auto',
    forecast_days: String(forecastDays)
  });
  const forecast = await fetchJson(forecastUrl);
  const daily = forecast.daily;
  if (!daily?.time?.length) {
    throw new Error('The weather service returned no forecast periods.');
  }

  return {
    location: {
      name: place.name,
      admin1: place.admin1 || null,
      country: place.country,
      latitude: place.latitude,
      longitude: place.longitude,
      timezone: forecast.timezone
    },
    forecast: daily.time.map((date, index) => ({
      date,
      conditions: weatherDescriptions.get(daily.weather_code[index]) || `Weather code ${daily.weather_code[index]}`,
      minimumTemperatureC: daily.temperature_2m_min[index],
      maximumTemperatureC: daily.temperature_2m_max[index],
      maximumPrecipitationProbabilityPercent: daily.precipitation_probability_max[index],
      maximumWindSpeedKph: daily.wind_speed_10m_max[index]
    }))
  };
}

module.exports = { getWeatherForecast };
