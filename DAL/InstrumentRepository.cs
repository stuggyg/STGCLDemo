using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using InstrumentSync.Models;

namespace InstrumentSync.DAL
{
    public class InstrumentRepository
    {
        private readonly string _connectionString;
        private readonly ILogger<InstrumentRepository> _logger;

        public InstrumentRepository(string connectionString, ILogger<InstrumentRepository> logger = null)
        {
            _connectionString = connectionString ?? throw new ArgumentNullException(nameof(connectionString));
            _logger = logger ?? NullLogger<InstrumentRepository>.Instance;
        }

        public async Task<List<Instrument>> GetInstrumentsAsync()
        {
            const string sql = "SELECT SerialNo, CPPartNo, PPPartNo, Desc, InputDate FROM Instruments";

            try
            {
                await using var connection = new SqlConnection(_connectionString);
                var result = await connection.QueryAsync<Instrument>(sql);
                return result.ToList();
            }
            catch (SqlException ex)
            {
                _logger.LogError(ex, "Failed to read instruments from database");
                throw new InvalidOperationException($"Failed to read instruments from database: {ex.Message}", ex);
            }
        }

        public List<Instrument> GetFakeInstruments(int count = 25)
        {
            var instruments = new List<Instrument>();

            for (int i = 1; i <= count; i++)
            {
                instruments.Add(new Instrument
                {
                    SerialNo = $"SN-{i:D4}",
                    CPPartNo = $"CP-{1000 + i}",
                    PPPartNo = $"PP-{2000 + i}",
                    Desc = $"Test Instrument {i}",
                    InputDate = DateTime.UtcNow.AddDays(-i)
                });
            }

            return instruments;
        }
    }
}
