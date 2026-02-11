/*
	Copyright 2006-2026 The QElectroTech Team
	This file is part of QElectroTech.

	QElectroTech is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 2 of the License, or
	(at your option) any later version.

	QElectroTech is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with QElectroTech.  If not, see <http://www.gnu.org/licenses/>.
*/
#ifndef QET_FILE_LOCK_H
#define QET_FILE_LOCK_H

#include <QLockFile>
#include <QMap>
#include <QString>

/**
	@brief Per-file locking to prevent two QET instances from editing the
	same .qet project simultaneously.

	Uses Qt's QLockFile which creates a <filepath>.lock sidecar file
	containing PID, hostname, and application name. Stale locks from
	crashed processes are automatically detected and broken.
*/
class QETFileLock
{
public:
	/**
		@brief Attempt to acquire an exclusive lock for the given file.
		@param filepath Canonical path of the .qet file to lock
		@return true if the lock was acquired, false if the file is
		        already locked by another process
	*/
	static bool tryLock(const QString &filepath);

	/**
		@brief Release the lock for the given file.
		@param filepath Canonical path of the .qet file to unlock
	*/
	static void unlock(const QString &filepath);

	/**
		@brief Check whether the given file is currently locked by this process.
		@param filepath Canonical path of the .qet file
		@return true if this process holds the lock
	*/
	static bool isLocked(const QString &filepath);

	/**
		@brief Get information about which process holds the lock.
		@param filepath Canonical path of the .qet file
		@param[out] pid PID of the locking process
		@param[out] hostname Hostname of the locking machine
		@param[out] appname Application name of the locking process
		@return true if lock info could be retrieved
	*/
	static bool lockInfo(const QString &filepath,
			     qint64 *pid,
			     QString *hostname,
			     QString *appname);

private:
	QETFileLock() = delete;
	static QMap<QString, QLockFile *> s_locks;
};

#endif // QET_FILE_LOCK_H
