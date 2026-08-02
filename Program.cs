using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using InstrumentSync.DAL;
using InstrumentSync.Models;

namespace InstrumentSync
{
    public class ChangeRequestApiClient
    {
        private static readonly JsonSerializerOptions DefaultJsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = null // PascalCase, matches property names as-is
        };

        private readonly HttpClient _httpClient;
        private readonly JsonSerializerOptions _jsonOptions;
        private readonly ILogger<ChangeRequestApiClient> _logger;

        public ChangeRequestApiClient(HttpClient httpClient, JsonSerializerOptions jsonOptions = null, ILogger<ChangeRequestApiClient> logger = null)
        {
            _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
            _jsonOptions = jsonOptions ?? DefaultJsonOptions;
            _logger = logger ?? NullLogger<ChangeRequestApiClient>.Instance;
        }

        public async Task<bool> InsertChangeRequestAsync(Instrument instrument)
        {
            ArgumentNullException.ThrowIfNull(instrument);

            if (string.IsNullOrWhiteSpace(instrument.SerialNo))
            {
                _logger.LogWarning("Skipping instrument with missing SerialNo.");
                return false;
            }

            try
            {
                var response = await _httpClient.PostAsJsonAsync("api/InsertChangeRequest", instrument, _jsonOptions);

                if (!response.IsSuccessStatusCode)
                {
                    _logger.LogWarning("{SerialNo}: API returned {StatusCode} {ReasonPhrase}", instrument.SerialNo, (int)response.StatusCode, response.ReasonPhrase);
                }

                return response.IsSuccessStatusCode;
            }
            catch (HttpRequestException ex)
            {
                _logger.LogError(ex, "{SerialNo}: Request failed", instrument.SerialNo);
                return false;
            }
            catch (TaskCanceledException ex)
            {
                _logger.LogError(ex, "{SerialNo}: Request timed out", instrument.SerialNo);
                return false;
            }
        }
    }

    public class Program
    {
        public static async Task Main(string[] args)
        {
            var configuration = new ConfigurationBuilder()
                .SetBasePath(AppContext.BaseDirectory)
                .AddJsonFile("appsettings.json", optional: false, reloadOnChange: false)
                .AddEnvironmentVariables()
                .Build();

            using var loggerFactory = LoggerFactory.Create(builder =>
                builder.AddConfiguration(configuration.GetSection("Logging")).AddConsole());

            var programLogger = loggerFactory.CreateLogger<Program>();

            var connectionString = configuration.GetConnectionString("InstrumentDb");
            var apiBaseUrl = configuration["ChangeRequestApi:BaseUrl"];

            var repository = new InstrumentRepository(connectionString, loggerFactory.CreateLogger<InstrumentRepository>());

            using var httpClient = new HttpClient { BaseAddress = new Uri(apiBaseUrl) };
            var apiClient = new ChangeRequestApiClient(httpClient, logger: loggerFactory.CreateLogger<ChangeRequestApiClient>());

            List<Instrument> instruments;
            try
            {
                // Real DB read (not called this run):
                // instruments = await repository.GetInstrumentsAsync();
                instruments = repository.GetFakeInstruments(25);
            }
            catch (Exception ex)
            {
                programLogger.LogError(ex, "Failed to load instruments");
                return;
            }

            foreach (var instrument in instruments)
            {
                var success = await apiClient.InsertChangeRequestAsync(instrument);
                programLogger.LogInformation("{SerialNo}: {Result}", instrument.SerialNo, success ? "OK" : "FAILED");
            }
        }
    }
}
