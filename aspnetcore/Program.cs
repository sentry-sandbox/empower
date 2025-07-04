using Sentry.Extensibility;

// Create the web application builder.
var builder = WebApplication.CreateBuilder(args);

// Configure API controllers, and JSON serialization options.
builder.Services.AddControllers()
    .AddJsonOptions(options =>
    {
        // Prevent cycles due to EF Core navigation properties.
        options.JsonSerializerOptions.ReferenceHandler = ReferenceHandler.IgnoreCycles;
        
        // Don't serialize properties that are null.
        options.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
    });

// Setup CORS to allow anything.
builder.Services.AddCors(options => options.AddDefaultPolicy(policy => policy
    .AllowAnyOrigin()
    .AllowAnyHeader()
    .AllowAnyMethod()));

// Add the database context.
builder.Services.AddDbContext<HardwareStoreContext>(options =>
{
    var connectionString = AppUtils.GetConnectionString(builder.Configuration);
    options.UseNpgsql(connectionString);

    options.AddInterceptors(new DemoCommandInterceptor());
});

// Initialize Sentry.
builder.WebHost.UseSentry(options =>
{
    // Set the DSN from the environment variable set by the deploy.sh script, if available.
    // But don't overwrite any existing DSN with null, as that would disable Sentry.
    var dsn = Environment.GetEnvironmentVariable("ASPNETCORE_APP_DSN");
    if (dsn != null)
    {
        options.Dsn = dsn;
    }

    // Set the release from the environment variable set by the deploy.sh script, if available.
    options.Release = Environment.GetEnvironmentVariable("RELEASE");

    // Enable some features.
    options.TracesSampleRate = 1.0;
    options.AutoSessionTracking = true;
    options.SendDefaultPii = true;

    // In development, allow the Sentry SDK to emit debug info to the console.
    if (builder.Environment.IsDevelopment())
    {
        options.Debug = true;
    }

    // https://docs.sentry.io/platforms/dotnet/guides/aspnetcore/#captureblockingcalls
    // Disabling until we make some improvements:
    // https://github.com/getsentry/sentry-dotnet/issues/4263
    // https://github.com/getsentry/sentry-dotnet/issues/4262
    // options.CaptureBlockingCalls = true;

    options.MaxRequestBodySize = RequestSize.Always; // Capture request body
});

// Add the HTTP Client factory.
builder.Services.AddHttpClient();

// Build the application.
var app = builder.Build();

// Add middleware components, including Sentry Tracing.
app.UseMiddleware<AppMiddleware>();
app.UseCors();

// Add global exception handler to ensure CORS headers are applied to error responses
app.Use(async (context, next) =>
{
    try
    {
        await next();
    }
    catch (Exception ex)
    {
        // Ensure CORS headers are applied even when exceptions occur
        context.Response.Headers.Add("Access-Control-Allow-Origin", "*");
        
        // Set error response
        context.Response.StatusCode = 500;
        context.Response.ContentType = "application/json";
        
        var errorResponse = new { error = "Internal Server Error" };
        await context.Response.WriteAsJsonAsync(errorResponse);
    }
});

app.UseSentryTracing();
app.MapControllers();

// Run the application.
app.Run();
