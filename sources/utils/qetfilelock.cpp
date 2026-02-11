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
#include "qetfilelock.h"

#include <QFileInfo>

QMap<QString, QLockFile *> QETFileLock::s_locks;

/**
	@brief QETFileLock::tryLock
	Attempt to acquire the lock for @a filepath.
	The lock file is placed next to the project file as "<filepath>.lock".
	If a stale lock is detected (e.g. from a crashed process), QLockFile
	will automatically break it.
	@param filepath Canonical path of the .qet file
	@return true if the lock was successfully acquired
*/
bool QETFileLock::tryLock(const QString &filepath)
{
	const QString canonical = QFileInfo(filepath).canonicalFilePath();
	if (canonical.isEmpty())
		return false;

	// Already locked by us
	if (s_locks.contains(canonical))
		return true;

	const QString lock_path = canonical + ".lock";
	QLockFile *lock = new QLockFile(lock_path);
	lock->setStaleLockTime(0); // Let QLockFile use its default stale detection

	if (lock->tryLock()) {
		s_locks.insert(canonical, lock);
		return true;
	}

	delete lock;
	return false;
}

/**
	@brief QETFileLock::unlock
	Release the lock for @a filepath and remove the lock file.
	@param filepath Canonical path of the .qet file
*/
void QETFileLock::unlock(const QString &filepath)
{
	const QString canonical = QFileInfo(filepath).canonicalFilePath();
	if (canonical.isEmpty())
		return;

	if (s_locks.contains(canonical)) {
		QLockFile *lock = s_locks.take(canonical);
		lock->unlock();
		delete lock;
	}
}

/**
	@brief QETFileLock::isLocked
	@param filepath Canonical path of the .qet file
	@return true if this process currently holds the lock
*/
bool QETFileLock::isLocked(const QString &filepath)
{
	const QString canonical = QFileInfo(filepath).canonicalFilePath();
	return s_locks.contains(canonical);
}

/**
	@brief QETFileLock::lockInfo
	Retrieve information about the process holding the lock.
	@param filepath Canonical path of the .qet file
	@param[out] pid PID of the lock holder
	@param[out] hostname Hostname of the lock holder
	@param[out] appname Application name of the lock holder
	@return true if info was successfully retrieved
*/
bool QETFileLock::lockInfo(const QString &filepath,
			   qint64 *pid,
			   QString *hostname,
			   QString *appname)
{
	const QString canonical = QFileInfo(filepath).canonicalFilePath();
	if (canonical.isEmpty())
		return false;

	const QString lock_path = canonical + ".lock";
	QLockFile lock(lock_path);
	return lock.getLockInfo(pid, hostname, appname);
}
