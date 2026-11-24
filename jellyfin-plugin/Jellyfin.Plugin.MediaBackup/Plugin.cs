using Jellyfin.Plugin.MediaBackup.Configuration;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;

namespace Jellyfin.Plugin.MediaBackup;

/// <summary>
/// Jellyfin plugin entry point for Media Backup.
/// </summary>
public class Plugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    public Plugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
    }

    public static Plugin? Instance { get; private set; }

    public override string Name => "Media Backup";

    public override Guid Id => Guid.Parse("a8f4c2e1-7b3d-4e9a-9c51-6d2f8b4e1a03");

    public override string Description => "Receive photo and video backups uploaded from mobile clients such as Finamp.";

    public IEnumerable<PluginPageInfo> GetPages()
    {
        return
        [
            new PluginPageInfo
            {
                Name = Name,
                EmbeddedResourcePath = $"{GetType().Namespace}.Configuration.configPage.html",
            },
        ];
    }
}
