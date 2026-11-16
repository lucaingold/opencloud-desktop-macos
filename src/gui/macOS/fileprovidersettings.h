/*
 * Copyright (C) 2026 OpenCloud GmbH
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

#pragma once

#include "libsync/configfile.h"
#include "libsync/graphapi/space.h"

#include <QStringList>
#include <QUuid>

// User choices for on-demand files, kept beside the folder sync settings.
namespace OCC::Mac {

inline QString deselectedFileProviderSpacesKey(const QUuid &account)
{
    return QStringLiteral("FileProvider/DeselectedSpaces/%1").arg(account.toString(QUuid::WithoutBraces));
}

/// The personal space is always shown, like the space set up by the account wizard on Windows.
inline bool isPersonalSpace(const GraphApi::Space *space)
{
    return space->drive().getDriveType() == QLatin1String("personal");
}

inline bool isFileProviderSpaceSelected(const QUuid &account, const GraphApi::Space *space)
{
    return isPersonalSpace(space)
        || !ConfigFile::makeQSettings().value(deselectedFileProviderSpacesKey(account)).toStringList().contains(space->id());
}

inline void setFileProviderSpaceSelected(const QUuid &account, const QString &spaceId, bool selected)
{
    auto settings = ConfigFile::makeQSettings();
    auto deselected = settings.value(deselectedFileProviderSpacesKey(account)).toStringList();
    deselected.removeAll(spaceId);
    if (!selected) {
        deselected.append(spaceId);
    }
    if (deselected.isEmpty()) {
        settings.remove(deselectedFileProviderSpacesKey(account));
    } else {
        settings.setValue(deselectedFileProviderSpacesKey(account), deselected);
    }
}

inline void forgetFileProviderSpaceSelection(const QUuid &account)
{
    ConfigFile::makeQSettings().remove(deselectedFileProviderSpacesKey(account));
}

inline bool fileProviderSyncPaused()
{
    return ConfigFile::makeQSettings().value(QStringLiteral("FileProvider/Paused"), false).toBool();
}

inline void setFileProviderSyncPaused(bool paused)
{
    ConfigFile::makeQSettings().setValue(QStringLiteral("FileProvider/Paused"), paused);
}

/// Matches the folder sync default: hidden files stay local unless the user opts in.
inline bool fileProviderIgnoresHiddenFiles()
{
    return ConfigFile::makeQSettings().value(QStringLiteral("FileProvider/IgnoreHiddenFiles"), true).toBool();
}

inline void setFileProviderIgnoresHiddenFiles(bool ignore)
{
    ConfigFile::makeQSettings().setValue(QStringLiteral("FileProvider/IgnoreHiddenFiles"), ignore);
}

} // namespace OCC::Mac
