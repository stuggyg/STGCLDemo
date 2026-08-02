var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapPost("/api/InsertChangeRequest", async (HttpContext context) =>
{
    using var reader = new StreamReader(context.Request.Body);
    var body = await reader.ReadToEndAsync();
    Console.WriteLine($"Received: {body}");
    return Results.Ok();
});

app.Run();
