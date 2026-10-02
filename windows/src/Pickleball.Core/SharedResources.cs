namespace Pickleball.Core;

public static class SharedResources
{
    public static Stream Open(string name) =>
        typeof(SharedResources).Assembly.GetManifestResourceStream("Pickleball.Shared." + name)
        ?? throw new FileNotFoundException("Embedded shared resource not found.", name);
}
