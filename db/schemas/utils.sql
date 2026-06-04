-- -----------------------------------------------------------------------
-- FUNÇÕES E OUTRAS COISAS
-- -----------------------------------------------------------------------

-- Função genérica que viabiliza coluna atualizado_em (schema:public)
CREATE OR REPLACE FUNCTION set_atualizado_em()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.atualizado_em = now();
    RETURN NEW;
END;
$$;

-- Função que inviabliza coluna search_vector
CREATE OR REPLACE FUNCTION cms.atualizar_search_vector()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.search_vector =
        setweight(to_tsvector('portuguese', coalesce(NEW.titulo, '')), 'A') ||
        setweight(to_tsvector('portuguese', coalesce(NEW.conteudo, '')), 'B');
    RETURN NEW;
END;
$$;

-- Cria automaticamente um perfil quando usuário é registrado
CREATE OR REPLACE FUNCTION public.criar_perfil_novo_usuario()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    INSERT INTO public.perfis (id, nome_inteiro)
    VALUES (NEW.id, NEW.raw_user_meta_data->>'full_name');
    RETURN NEW;
END;
$$;

-- Função que armazena versão anterior dos artigos sempre que
-- título ou conteúdo é alterado
CREATE OR REPLACE FUNCTION cms.registrar_revisao_artigo()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_editor UUID;
BEGIN
    v_editor := COALESCE(
        NULLIF(current_setting('app.editor_id', true), '')::uuid,
        auth.uid(),
        OLD.autor_id  -- último recurso é o autor original
    );
    IF v_editor IS NULL THEN
        RAISE EXCEPTION
            'Não foi possível identificar o editor do artigo % '
            '(defina app.editor_id na transação)', OLD.id;
    END IF;

    -- Guarda estado anterior (versão substituída)
    INSERT INTO cms.revisoes_de_artigos (artigo_id, editor_id, titulo, conteudo)
    VALUES (OLD.id, v_editor, OLD.titulo, OLD.conteudo);

    RETURN NULL; -- depois de trigger, valor é ignorado
END;
$$;

CREATE TRIGGER trg_artigos_revisao
    AFTER UPDATE ON cms.artigos
    FOR EACH ROW
    WHEN (OLD.titulo IS DISTINCT FROM NEW.titulo
          OR OLD.conteudo IS DISTINCT FROM NEW.conteudo)
    EXECUTE FUNCTION cms.registrar_revisao_artigo();

-- ==========================================================
-- Função que atualiza status do artigo de 'agendado' para 'publicado'

CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION cms.publicar_artigos_agendados()
RETURNS void
LANGUAGE sql
AS $$
    UPDATE cms.artigos
    SET status = 'publicado',
        publicado_em = now()
    WHERE status = 'agendado'
      AND agendado_para <= now();
$$;

-- COnfigurar a função para ser executada a cada minuto
SELECT cron.schedule(
    'publicar_artigos_agendados',
    '* * * * *', -- a cada minuto
    $$ SELECT cms.publicar_artigos_agendados(); $$
);
