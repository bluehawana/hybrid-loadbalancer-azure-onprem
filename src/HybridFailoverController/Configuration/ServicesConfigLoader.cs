using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace HybridFailoverController.Configuration;

public static class ServicesConfigLoader
{
    public static ServicesConfig Load(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Services config not found: {path}");

        var deserializer = new DeserializerBuilder()
            .WithNamingConvention(CamelCaseNamingConvention.Instance)
            .IgnoreUnmatchedProperties()
            .Build();

        return deserializer.Deserialize<ServicesConfig>(File.ReadAllText(path)) ?? new ServicesConfig();
    }
}
