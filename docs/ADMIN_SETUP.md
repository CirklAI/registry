# Admin Panel Setup Guide

This guide explains how to set up the admin panel for the Cirkl Registry.

## One-Time Setup

The admin panel uses a one-time setup process. On first access, you'll be
prompted to create an admin password.

### Accessing Setup

1. Start the server:

```bash
dart run
```

2. Navigate to `/admin/setup` in your browser

3. Enter a strong password (minimum 12 characters)

4. The system will create a `.registry_admin_config` file with:
   - A bcrypt-hashed password
   - A secure session secret
   - File permissions set to 600 (owner read/write only)

### Manual Setup (Advanced)

If you need to set up the admin configuration manually or programmatically, you
can generate the configuration file directly.

#### Generate Password Hash

To generate a bcrypt hash for your password using only UNIX tools: OpenSSL:

```bash
PASSWORD="your_secure_password_here"
echo -n "$PASSWORD" | openssl passwd -stdin -6
```

or Python <3

```bash
python3 -c "import bcrypt; print(bcrypt.hashpw('$PASSWORD'.encode(), bcrypt.gensalt()).decode())"
```

> ![NOTE] The Dart application uses the `bcrypt` package which generates hashes
> compatible with standard bcrypt implementations.

#### Generate Session Secret

Generate a secure random session secret using only UNIX tools:

```bash
head -c 32 /dev/urandom | base64
```

#### Create Configuration File

If creation fails, you can create the `.registry_admin_config` file manually:

```bash
cat > .registry_admin_config << EOF
{
  "password_hash": "$(python3 -c "import bcrypt; print(bcrypt.hashpw('YOUR_PASSWORD'.encode(), bcrypt.gensalt()).decode())")",
  "session_secret": "$(head -c 32 /dev/urandom | base64)",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
```

then set restrictive permission:

```bash
chmod 600 .registry_admin_config
```

> ![NOTE] PLEASE remember to replace `YOUR_PASSWORD` with your actual password.

## Accessing the Admin Panel

1. Navigate to `/admin/login`
2. Enter your admin password
3. You'll be redirected to `/admin` where you can:
   - Add new programs
   - Add vulnerabilities to programs
   - Manage program information

## Changing Password

To change your admin password:

1. Log in to the admin panel
2. The password change functionality can be added via API or by:
   - Deleting `.registry_admin_config`
   - Running setup again

## Troubleshooting

### Configuration File Not Found

If the setup page shows an error about configuration:

- Ensure the server has write permissions in the current directory
- Check that `.registry_admin_config` exists and has correct permissions (600)

### Cannot Login

- Verify the password is correct
- Check that `.registry_admin_config` exists and is readable
- Ensure the file has correct JSON format
- Check server logs for authentication errors

### Session Expired

- Sessions expire after 24 hours
- Simply log in again to create a new session

## File Locations

- **Configuration**: `.registry_admin_config` (in the directory where the server
  is run)
- **Database**: In-memory cache SQLite and disk writes
