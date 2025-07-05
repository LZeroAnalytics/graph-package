# The min/max CPU/memory that postgres can use
POSTGRES_MIN_CPU = 10
POSTGRES_MAX_CPU = 1000
POSTGRES_MIN_MEMORY = 32
POSTGRES_MAX_MEMORY = 1024

def run(plan, ethereum_args=None, network_type="bloctopus", rpc_url=None, env="main", prefix=""):

    plan.print("Running graph package on branch {}".format(env))

    postgres = import_module("github.com/tiljrd/postgres-package@{}/main.star".format(env))
    ethereum = import_module("github.com/LZeroAnalytics/ethereum-package@{}/main.star".format(env))

    if not rpc_url:
        plan.print("Running the ethereum package")
        result = ethereum.run(plan, ethereum_args)
        first = result.all_participants[0]
        rpc_url = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num)

    postgres_output = postgres.run(
        plan,
        service_name="{}postgres".format(prefix),
        min_cpu=POSTGRES_MIN_CPU,
        max_cpu=POSTGRES_MAX_CPU,
        min_memory=POSTGRES_MIN_MEMORY,
        max_memory=POSTGRES_MAX_MEMORY,
        extra_env_vars={
            "POSTGRES_INITDB_ARGS": "-E UTF8 --locale=C"
        }
    )

    postgres_user = postgres_output.user
    postgres_password = postgres_output.password
    postgres_hostname = postgres_output.service.hostname
    postgres_database = postgres_output.database

    ipfs_output = plan.add_service(
        name="{}ipfs".format(prefix),
        config=ServiceConfig(
            image="ipfs/kubo:master-latest",
            ports={
               "rpc": PortSpec(number=5001, transport_protocol="TCP"),
                "p2p": PortSpec(number=4001, transport_protocol="TCP"),
                "gateway": PortSpec(number=8080, transport_protocol="TCP", application_protocol="http")
            }
        )
    )

    ipfs_ip = ipfs_output.ip_address
    ipfs_url = "{}:5001".format(ipfs_ip)

    plan.print(ipfs_output)
    plan.print(ipfs_url)

    # Build environment variables
    env_vars = {
        "postgres_host": postgres_hostname,
        "postgres_user": postgres_user,
        "postgres_pass": postgres_password,
        "postgres_db": postgres_database,
        "ipfs": ipfs_url,
        "ethereum": "{}:{}".format(network_type, rpc_url)
    }
    
    files = {}
    
    # Add substreams configuration if endpoint is provided
    if ethereum_args and "substreams_endpoint" in ethereum_args:
        substreams_endpoint = ethereum_args["substreams_endpoint"]
        
        # Create TOML configuration for substreams support without template processing
        config_content = "[general]\n\n"
        config_content += "[store]\n"
        config_content += "[store.primary]\n"
        config_content += "connection = \"postgresql://{}:{}@{}:{}/{}\"\n".format(postgres_user, postgres_password, postgres_hostname, "5432", postgres_database)
        config_content += "weight = 1\n"
        config_content += "pool_size = 10\n\n"
        config_content += "[chains]\n"
        config_content += "ingestor = \"block_ingestor_node\"\n\n"
        config_content += "[chains.{}]\n".format(network_type)
        config_content += "protocol = \"substreams\"\n"
        config_content += "shard = \"primary\"\n"
        config_content += "provider = [\n"
        config_content += "    { label = \"substreams\", details = { type = \"substreams\", url = \"{}\", features = [\n".format(substreams_endpoint)
        config_content += "        \"compression\",\n"
        config_content += "        \"filters\",\n"
        config_content += "    ], conn_pool_size = 1 } },\n"
        config_content += "]\n\n"
        config_content += "[chains.{}-rpc]\n".format(network_type)
        config_content += "protocol = \"ethereum\"\n"
        config_content += "shard = \"primary\"\n"
        config_content += "provider = [\n"
        config_content += "    { label = \"rpc\", details = { type = \"web3\", url = \"{}\", features = [] } },\n".format(rpc_url)
        config_content += "]\n\n"
        config_content += "[deployment]\n"
        config_content += "[[deployment.rule]]\n"
        config_content += "shard = \"primary\"\n"
        config_content += "indexers = [\"default\"]\n"
        
        # Create config file artifact without template processing
        config_artifact = plan.render_templates(
            config={
                "config.toml": struct(template=config_content, data={})
            },
            name="graph-node-config"
        )
        
        files["/etc/graph-node"] = config_artifact
        env_vars["GRAPH_NODE_CONFIG"] = "/etc/graph-node/config.toml"

    graph_output = plan.add_service(
        name="{}graph-node".format(prefix),
        config=ServiceConfig(
            image="graphprotocol/graph-node",
            ports={
                "http": PortSpec(number=8000, transport_protocol="TCP", application_protocol="http", wait=None),
                "ws": PortSpec(number=8001, transport_protocol="TCP", wait=None),
                "rpc": PortSpec(number=8020, transport_protocol="TCP", wait=None),
                "api": PortSpec(number=8030, transport_protocol="TCP", wait=None),
                "prometheus": PortSpec(number=8040, transport_protocol="TCP", wait=None)
            },
            env_vars=env_vars,
            files=files
        )
    )

    graph_services = struct(
        postgres = postgres_output,
        ipfs = ipfs_output,
        graph = graph_output
    )

    return graph_services
