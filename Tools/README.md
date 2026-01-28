# MRP CLI Tool

A command-line tool for interrogating mrpd REST APIs.

## Installation

The tool requires Python 3 and the `requests` library:

```bash
pip install requests
```

Make the script executable:
```bash
chmod +x mrp
```

## Usage

```
./mrp [--host HOST] [--port PORT] [--format FORMAT] {msrp|mvrp|mmrp} ...
```

### Global Options

- `--host HOST` - mrpd host (default: localhost)
- `--port PORT` - mrpd REST API port (default: 80)
- `--format {json|table}` - Output format (default: table)

### MSRP (Multiple Stream Reservation Protocol)

#### List all ports
```bash
./mrp msrp port
```

#### Show details for a specific port
```bash
./mrp msrp port eth0
```

This displays:
- Port status (enabled, AS capable, forwarding)
- Talker streams (stream ID, destination, latency, registration status)
- Failed talker streams (with failure codes and reasons)
- Listener streams (stream ID, type, registration status)
- SR class information (Class A/B with bandwidth, priority, VLAN)

#### List all streams
```bash
./mrp msrp stream
```

#### Show details for a specific stream
```bash
./mrp msrp stream 91e0f000f7d4c0004139aabbccdd00aa
```

This displays:
- Stream properties (destination, VLAN, priority, bandwidth, rank)
- Talker information (port, type)
- Listener information (ports, connection status)

### MVRP (Multiple VLAN Registration Protocol)

#### List all ports
```bash
./mrp mvrp port
```

#### Show VLANs on a specific port
```bash
./mrp mvrp port eth0
```

This displays all registered VLANs with their registration and declaration status.

### MMRP (Multiple MAC Registration Protocol)

#### List all ports
```bash
./mrp mmrp port
```

#### Show MAC addresses on a specific port
```bash
./mrp mmrp port eth0
```

This displays all registered MAC addresses with their registration and declaration status.

## Examples

### Connect to a remote mrpd instance
```bash
./mrp --host 10.10.32.205 msrp port
```

### Get JSON output
```bash
./mrp --format json msrp stream 91e0f000f7d4c0004139aabbccdd00aa
```

### Query MSRP status on a specific port
```bash
./mrp --host 10.10.32.205 msrp port eth0
```

### List all registered streams
```bash
./mrp --host 10.10.32.205 msrp stream
```

## Output Formats

### Table Format (default)
Human-readable tables with aligned columns.

### JSON Format
Raw JSON output from the API, useful for scripting and automation.
