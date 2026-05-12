# Heartbeat Checklist

## Daily
- [ ] Check NVD/CVE feed for Critical/High advisories affecting active stack
- [ ] Check for new security advisories in GitHub repos being monitored
- [ ] Review system auth logs for anomalies (failed logins, sudo abuse)

## System
- [ ] Check open ports and listening services — flag unexpected changes
- [ ] Check for world-writable files in sensitive paths
- [ ] Verify inference services are running with expected configurations

## Weekly
- [ ] Audit active dependencies for known vulnerabilities (pip, cargo, npm)
- [ ] Check for outdated certificates or expiring credentials
- [ ] Review firewall rules and network exposure
